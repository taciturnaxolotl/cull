import CoreGraphics
import Foundation
import SQLite3

/// Persists workspace state (ratings, flags, analysis, groups) in a SQLite database
/// stored as `.cull.db` in the source photo folder.
final class WorkspaceDB: @unchecked Sendable {
    private var db: OpaquePointer?
    private let dbURL: URL

    init?(folder: URL) {
        self.dbURL = folder.appendingPathComponent(".cull.db")
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { return nil }

        // WAL mode for better concurrent read/write
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")

        createTables()
        migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Schema

    private func createTables() {
        exec("""
            CREATE TABLE IF NOT EXISTS photos (
                path TEXT PRIMARY KEY,
                paired_path TEXT,
                rating INTEGER DEFAULT 0,
                flag TEXT DEFAULT 'none',
                blur_score REAL,
                face_sharpness REAL,
                face_regions TEXT,
                pixel_width INTEGER DEFAULT 0,
                pixel_height INTEGER DEFAULT 0,
                file_size INTEGER DEFAULT 0,
                paired_pixel_width INTEGER DEFAULT 0,
                paired_pixel_height INTEGER DEFAULT 0,
                paired_file_size INTEGER DEFAULT 0,
                capture_date REAL,
                group_id TEXT,
                eye_aspect_ratios TEXT
            )
        """)

        exec("""
            CREATE TABLE IF NOT EXISTS groups (
                group_id TEXT PRIMARY KEY,
                sort_order INTEGER
            )
        """)

        exec("""
            CREATE TABLE IF NOT EXISTS settings (
                key TEXT PRIMARY KEY,
                value TEXT
            )
        """)
    }

    private func migrate() {
        // Add eye_aspect_ratios column if missing (added in v2)
        exec("ALTER TABLE photos ADD COLUMN eye_aspect_ratios TEXT")
    }

    // MARK: - Save

    func savePhotos(_ photos: [Photo], sourceFolder: URL) {
        exec("BEGIN TRANSACTION")
        let stmt = prepare("""
            INSERT OR REPLACE INTO photos
            (path, paired_path, rating, flag, blur_score, face_sharpness, face_regions,
             pixel_width, pixel_height, file_size,
             paired_pixel_width, paired_pixel_height, paired_file_size, capture_date, group_id,
             eye_aspect_ratios)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """)
        defer { sqlite3_finalize(stmt) }

        for photo in photos {
            let relativePath = photo.url.relativePath(from: sourceFolder)
            let pairedPath = photo.pairedURL?.relativePath(from: sourceFolder)
            let flagStr = flagToString(photo.flag)
            let regionsJSON = encodeRegions(photo.faceRegions)

            sqlite3_reset(stmt)
            bind(stmt, 1, relativePath)
            bind(stmt, 2, pairedPath)
            bind(stmt, 3, photo.rating)
            bind(stmt, 4, flagStr)
            bind(stmt, 5, photo.blurScore)
            bind(stmt, 6, photo.faceSharpness)
            bind(stmt, 7, regionsJSON)
            bind(stmt, 8, photo.pixelWidth)
            bind(stmt, 9, photo.pixelHeight)
            bind(stmt, 10, photo.fileSize)
            bind(stmt, 11, photo.pairedPixelWidth)
            bind(stmt, 12, photo.pairedPixelHeight)
            bind(stmt, 13, photo.pairedFileSize)
            bind(stmt, 14, photo.captureDate?.timeIntervalSinceReferenceDate)
            bind(stmt, 15, nil as String?) // group_id set separately
            bind(stmt, 16, encodeDoubles(photo.eyeAspectRatios))
            sqlite3_step(stmt)
        }
        exec("COMMIT")
    }

    func saveGroups(_ groups: [PhotoGroup], sourceFolder: URL) {
        exec("BEGIN TRANSACTION")
        exec("DELETE FROM groups")

        let groupStmt = prepare("INSERT INTO groups (group_id, sort_order) VALUES (?,?)")
        let photoStmt = prepare("UPDATE photos SET group_id = ? WHERE path = ?")
        defer {
            sqlite3_finalize(groupStmt)
            sqlite3_finalize(photoStmt)
        }

        for (i, group) in groups.enumerated() {
            let groupID = group.id.uuidString
            sqlite3_reset(groupStmt)
            bind(groupStmt, 1, groupID)
            bind(groupStmt, 2, i)
            sqlite3_step(groupStmt)

            for photo in group.photos {
                sqlite3_reset(photoStmt)
                bind(photoStmt, 1, groupID)
                bind(photoStmt, 2, photo.url.relativePath(from: sourceFolder))
                sqlite3_step(photoStmt)
            }
        }
        exec("COMMIT")
    }

    func saveSetting(_ key: String, _ value: String?) {
        if let value {
            let stmt = prepare("INSERT OR REPLACE INTO settings (key, value) VALUES (?,?)")
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, key)
            bind(stmt, 2, value)
            sqlite3_step(stmt)
        } else {
            let stmt = prepare("DELETE FROM settings WHERE key = ?")
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, key)
            sqlite3_step(stmt)
        }
    }

    func saveSettings(session: CullSession) {
        saveSetting("selectedGroupIndex", "\(session.selectedGroupIndex)")
        saveSetting("selectedPhotoIndex", "\(session.selectedPhotoIndex)")
        saveSetting("hidePicks", session.hidePicks ? "1" : "0")
        saveSetting("hideRejects", session.hideRejects ? "1" : "0")
        saveSetting("hideUnrated", session.hideUnrated ? "1" : "0")
        saveSetting("hiddenRatings", session.hiddenRatings.map(String.init).joined(separator: ","))
        saveSetting("importRecursive", session.importRecursive ? "1" : "0")
    }

    // MARK: - Load

    struct SavedPhoto {
        let path: String
        let pairedPath: String?
        let rating: Int
        let flag: PhotoFlag
        let blurScore: Double?
        let faceSharpness: Double?
        let faceRegions: [CGRect]
        let pixelWidth: Int
        let pixelHeight: Int
        let fileSize: Int64
        let pairedPixelWidth: Int
        let pairedPixelHeight: Int
        let pairedFileSize: Int64
        let captureDate: Date?
        let groupID: String?
        let eyeAspectRatios: [Double]
    }

    func loadPhotos() -> [SavedPhoto] {
        let stmt = prepare("SELECT * FROM photos")
        defer { sqlite3_finalize(stmt) }

        var results: [SavedPhoto] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let path = getString(stmt, 0) ?? ""
            let pairedPath = getString(stmt, 1)
            let rating = Int(sqlite3_column_int(stmt, 2))
            let flag = stringToFlag(getString(stmt, 3) ?? "none")
            let blurScore = getOptionalDouble(stmt, 4)
            let faceSharpness = getOptionalDouble(stmt, 5)
            let regionsJSON = getString(stmt, 6)
            let pixelWidth = Int(sqlite3_column_int(stmt, 7))
            let pixelHeight = Int(sqlite3_column_int(stmt, 8))
            let fileSize = sqlite3_column_int64(stmt, 9)
            let pairedPixelWidth = Int(sqlite3_column_int(stmt, 10))
            let pairedPixelHeight = Int(sqlite3_column_int(stmt, 11))
            let pairedFileSize = sqlite3_column_int64(stmt, 12)
            let captureDateInterval = getOptionalDouble(stmt, 13)
            let groupID = getString(stmt, 14)
            let earJSON = getString(stmt, 15)

            results.append(SavedPhoto(
                path: path,
                pairedPath: pairedPath,
                rating: rating,
                flag: flag,
                blurScore: blurScore,
                faceSharpness: faceSharpness,
                faceRegions: decodeRegions(regionsJSON),
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                fileSize: fileSize,
                pairedPixelWidth: pairedPixelWidth,
                pairedPixelHeight: pairedPixelHeight,
                pairedFileSize: pairedFileSize,
                captureDate: captureDateInterval.map { Date(timeIntervalSinceReferenceDate: $0) },
                groupID: groupID,
                eyeAspectRatios: decodeDoubles(earJSON)
            ))
        }
        return results
    }

    func loadGroupOrder() -> [String] {
        let stmt = prepare("SELECT group_id FROM groups ORDER BY sort_order")
        defer { sqlite3_finalize(stmt) }
        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let id = getString(stmt, 0) { ids.append(id) }
        }
        return ids
    }

    func loadSetting(_ key: String) -> String? {
        let stmt = prepare("SELECT value FROM settings WHERE key = ?")
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, key)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return getString(stmt, 0)
    }

    func loadSettings(into session: CullSession) {
        if let v = loadSetting("selectedGroupIndex"), let i = Int(v) { session.selectedGroupIndex = i }
        if let v = loadSetting("selectedPhotoIndex"), let i = Int(v) { session.selectedPhotoIndex = i }
        if let v = loadSetting("hidePicks") { session.hidePicks = v == "1" }
        if let v = loadSetting("hideRejects") { session.hideRejects = v == "1" }
        if let v = loadSetting("hideUnrated") { session.hideUnrated = v == "1" }
        if let v = loadSetting("hiddenRatings"), !v.isEmpty {
            session.hiddenRatings = Set(v.split(separator: ",").compactMap { Int($0) })
        }
        if let v = loadSetting("importRecursive") { session.importRecursive = v == "1" }
    }

    /// Returns true if this database has cached photo data
    var hasCachedData: Bool {
        let stmt = prepare("SELECT COUNT(*) FROM photos")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        return sqlite3_column_int(stmt, 0) > 0
    }

    // MARK: - Helpers

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        return stmt
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int) {
        sqlite3_bind_int(stmt, index, Int32(value))
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int64) {
        sqlite3_bind_int64(stmt, index, value)
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func getString(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    private func getOptionalDouble(_ stmt: OpaquePointer?, _ index: Int32) -> Double? {
        if sqlite3_column_type(stmt, index) == SQLITE_NULL { return nil }
        return sqlite3_column_double(stmt, index)
    }

    private func flagToString(_ flag: PhotoFlag) -> String {
        switch flag {
        case .none: "none"
        case .pick: "pick"
        case .reject: "reject"
        }
    }

    private func stringToFlag(_ str: String) -> PhotoFlag {
        switch str {
        case "pick": .pick
        case "reject": .reject
        default: .none
        }
    }

    private func encodeRegions(_ regions: [CGRect]) -> String? {
        guard !regions.isEmpty else { return nil }
        let arrays = regions.map { [Double($0.origin.x), Double($0.origin.y), Double($0.width), Double($0.height)] }
        guard let data = try? JSONSerialization.data(withJSONObject: arrays) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func encodeDoubles(_ values: [Double]) -> String? {
        guard !values.isEmpty else { return nil }
        return values.map { String(format: "%.3f", $0) }.joined(separator: ",")
    }

    private func decodeDoubles(_ str: String?) -> [Double] {
        guard let str, !str.isEmpty else { return [] }
        return str.split(separator: ",").compactMap { Double($0) }
    }

    private func decodeRegions(_ json: String?) -> [CGRect] {
        guard let json, let data = json.data(using: .utf8),
              let arrays = try? JSONSerialization.jsonObject(with: data) as? [[Double]] else { return [] }
        return arrays.compactMap { arr in
            guard arr.count == 4 else { return nil }
            return CGRect(x: arr[0], y: arr[1], width: arr[2], height: arr[3])
        }
    }
}

extension URL {
    func relativePath(from base: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let selfPath = self.standardizedFileURL.path
        if selfPath.hasPrefix(basePath) {
            let relative = String(selfPath.dropFirst(basePath.count))
            return relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
        }
        return selfPath
    }
}
