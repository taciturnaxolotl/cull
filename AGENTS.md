# AGENTS.md

## Project Overview

Cull is a macOS photo culling app built in Swift/SwiftUI. It imports RAW+JPEG photos, groups similar shots using temporal clustering and Vision feature prints, detects faces and closed eyes, and provides a keyboard-driven culling workflow with XMP sidecar export for Lightroom/Bridge interoperability.

Bundle ID: `sh.dunkirk.cull`. Minimum deployment target: macOS 26.2. Swift 5. Only external dependency is Sparkle (auto-updates). Zero third-party dependencies for the core pipeline — everything uses Apple frameworks (ImageIO, Vision, CoreImage, AppKit).

## Build & Run

```bash
# Build from CLI
xcodebuild -project cull/cull.xcodeproj -scheme cull -configuration Debug build

# Resolve SPM deps
xcodebuild -resolvePackageDependencies -project cull/cull.xcodeproj -scheme cull

# Run tests (if any exist)
xcodebuild test -project cull/cull.xcodeproj -scheme cull -destination 'platform=macOS'
```

No Makefile, no Taskfile, no test targets currently configured. All development is through Xcode or xcodebuild.

## Architecture

### Data Flow

```
Import → Group → Analyze → Display → Cull → Export
```

1. **PhotoImporter** scans a folder, matches RAW+JPEG pairs by basename, reads EXIF metadata in parallel batches of 16
2. **ShotGrouper** clusters photos temporally (30s gap threshold), then sub-clusters by visual similarity using `VNGenerateImageFeaturePrintRequest` (threshold 0.6, Revision 2), then merges adjacent groups within 5s that are visually similar
3. **QualityAnalyzer** detects faces (capture quality + landmarks for EAR blink detection) at 1600px, ordering them as a left-to-right sweep. It carries an `analysisVersion`; workspaces record the version they were analyzed with and re-run on mismatch, so corrections reach existing projects
4. **ThumbnailCache** provides three-tier caching: NSCache in-memory (500 items, 100MB), disk cache in `~/Library/Caches/sh.dunkirk.Cull.thumbnails/`, and on-demand extraction via `CGImageSourceCreateThumbnailAtIndex`
5. **CullSession** (`@Observable`) is the central state object passed via `.environment()`. Manages navigation, filters, ratings, flags, undo, and workspace persistence
6. **WorkspaceDB** persists all state to `.cull.db` (SQLite, WAL mode) in the source photo folder. Debounced auto-save at 500ms. Saves photos+groups in a single transaction for atomicity
7. **XMPSidecar** writes `<basename>.xmp` files (Lightroom-compatible naming). Reject maps to `xmp:Rating=-1`. Merges into existing XMP rather than overwriting

### Key Models

- **Photo** (`@Observable`): id, url, pairedURL, rating (0-5), flag (none/pick/reject), faceRegions, eyeAspectRatios, captureDate, pixel dimensions. `imageURL` prefers the paired JPEG for decode speed
- **PhotoGroup** (`@Observable`): id, photos array, representativePhoto, earliestDate
- **CullSession** (`@Observable`): groups, selectedGroupIndex, selectedPhotoIndex, zoom transform (zoomScale + zoomAnchor + zoomFaceIndex), filter state, workspace DB handle

### View Structure

- **ContentView**: top-level router (import → progress → empty → culling). Receives notifications for openFolder, showExport, reimport
- **PhotoViewer**: main culling view with progressive image loading (thumbnail → preview), face overlays, zoom and pan (wheel/pinch to zoom, drag or two-finger scroll to pan, space to cycle presets), debug cache overlay
- **GroupListView / GroupDetailView**: sidebar navigation
- **ExportSheet**: copy/move with folder structure options (flat, RAW/JPEG split, by rating, combined)
- **SettingsView**: app preferences

### Keyboard Shortcuts

Defined in `CullApp.swift` via `.commands`:
- `P` = pick, `X` = reject, `0` = clear rating/flag, `1-5` = star rating
- `↑/↓` = prev/next photo, `←/→` = prev/next group
- `Space` = cycle zoom (fit → faces → center → fit)
- `⌘O` = open folder, `⌘E` = export, `⌘W` = close folder

## Non-Obvious Patterns & Gotchas

### RAW File Handling
- Always use `photo.imageURL` (not `photo.url`) for thumbnails and display — this returns the paired JPEG when available, which decodes 10-100× faster than RAW
- For analysis, `QualityAnalyzer.sourceForAnalysis()` finds the largest embedded preview in multi-image RAW containers (index > 0), not the RAW data itself
- Use `kCGImageSourceShouldCache: false` everywhere to prevent ImageIO from retaining full decoded images in memory
- CR3 files with HDR PQ–enabled HEVC previews cause excessive CPU usage in the system's `ImageThumbnailExtension` on macOS Sequoia 15.1. Test with Canon R5 Mark II files specifically
- Performance reference (Apple Silicon): embedded JPEG preview extraction ~15-50ms/file, EXIF metadata read ~2-4ms/file, full RAW decode via CIRAWFilter ~50-3000ms (impractical for bulk). Bulk thumbnail generation for 1000 RAW files with 8-way parallelism: ~2-6s

### Feature Print Thresholds
- The codebase uses Revision 2 thresholds (0.0–2.0 range, 768-dim vectors). Revision 1 produces 2048-dim unnormalized vectors with distances up to ~40. Do not mix thresholds across revisions
- Current similarity threshold is 0.6 (lenient grouping of different framings). Use ~0.35 for near-duplicate detection specifically
- Feature print generation takes ~15-50ms/image on Apple Silicon (neural network inference bottleneck). Cache aggressively — 768 floats × 4 bytes = ~3KB/image

### Workspace Persistence
- `.cull.db` lives *in the source photo folder*, not in app support. This makes workspaces portable but means the app needs security-scoped resource access
- Photos and groups are saved in a single SQLite transaction. The old two-step approach was replaced because a crash between writes would lose all group assignments
- On reopen, the workspace loader scans for new files on disk not in the DB and returns them as `newPhotos` for incremental analysis
- Schema migrations use `ALTER TABLE ADD COLUMN` (safe for additive changes only)

### XMP Sidecar Compatibility
- Pick/reject flags do NOT exist in XMP. Reject is stored as `xmp:Rating=-1` (Adobe Bridge convention). Lightroom users must use color labels or star ratings instead
- Always read existing sidecars before writing to avoid clobbering Camera Raw develop settings
- File naming: `<basename>.xmp` (not `<basename>.<ext>.xmp`) for Lightroom compatibility

### SwiftUI Focus
- The viewer uses `@FocusState` and `.focusable()`. If keyboard shortcuts stop working, check that focus hasn't been lost to another UI element
- Navigation skips filtered photos automatically — `moveToNextPhoto()` and `moveToPreviousPhoto()` iterate until finding an unfiltered photo, wrapping to adjacent groups

### Thumbnail Cache Identity
- Cache keys use `photo.url.absoluteString` (the RAW URL), but loading uses `photo.imageURL` (the JPEG). This ensures cache identity is stable regardless of pairing state
- Disk cache filenames use a SHA256 hash of the URL to avoid filesystem issues with long paths
- `cacheGeneration` counter bumps on state changes to trigger SwiftUI re-renders for the debug overlay

### Preview Cache Sizing
- Previews are the app's real memory footprint: a 2560px preview of a 24MP frame decodes to ~17MB. The preview cache is bounded by `totalCostLimit` (1GB), not `countLimit`, so per-image costs must be accurate or the cache silently holds a fraction of what it should
- Measure cost from `NSImage.size`, never from `representations.first.pixelsWide`. An `NSImage(cgImage:size:)` is backed by an `NSCGImageSnapshotRep` that reports pixel dimensions multiplied by the display scale factor — on Retina that overstates every preview by 4x. A disk-loaded `NSBitmapImageRep` reports true pixels, so the two disagree and only `size` is correct for both
- Keep `CullSession.previewWindow()` comfortably under the byte budget (~37 entries, ~650MB against 1GB). NSCache eviction order is unspecified, so a window sized to the brim loses photos the user is walking toward
- Preview decode is not the bottleneck: ~65ms serial, ~17ms/image at 4-way parallelism for 6000x4000 JPEGs on Apple Silicon. If previews feel slow, suspect eviction or a skipped display update before suspecting decode
- `kCGImageSourceCreateThumbnailFromImageIfAbsent` returns the *embedded* EXIF thumbnail whenever one exists, treating `kCGImageSourceThumbnailMaxPixelSize` as a ceiling only. Sony JPEGs carry a 160px thumbnail, so strip thumbnails come back at 160px despite the 400px request

### Viewer Load State
- `PhotoViewer`'s load task tracks what it has displayed in a local variable, not by reading back `@State`. SwiftUI can start `.task` before `onAppear` and before `onChange` updates those flags, so they may still describe the previous photo
- Never gate the full-res upgrade on "is it cached?" — the background loader frequently caches the current photo mid-task, and the viewer then skips the upgrade and sits on the thumbnail

### Progress Reporting During Import
- Import has three parallel streams (analysis 40%, thumbnails 35%, previews 25%) after the initial grouping phase (0-20%)
- Uses `nonisolated(unsafe)` for progress variables shared across concurrent tasks — safe because each variable is written by exactly one task
- Preview preloading at import only covers the first 24 and last 12 visible photos; the rest load on demand through the navigation window

### Notification-Based Communication
- Cross-component communication uses `NotificationCenter` with custom names (`.openFolder`, `.showExport`, `.reimport`), not bindings or environment. This decouples menu commands from views

## Release Process

CI runs on GitHub Actions (`release.yml`) triggered by release creation or manual dispatch:
1. Builds with `xcodebuild archive` using Developer ID signing
2. Creates DMG, signs with codesign, notarizes with `xcrun notarytool`
3. Signs DMG with Sparkle Ed25519 key via `sign_update`
4. Uploads DMG to GitHub release
5. Updates `docs/appcast.xml` via `scripts/update-appcast.sh` for Sparkle auto-updates

Appcast is served from `https://taciturnaxolotl.github.io/cull/appcast.xml` (GitHub Pages).

## Code Conventions

- Services are stateless structs with static methods (PhotoImporter, QualityAnalyzer, ShotGrouper, PhotoExporter, XMPSidecar)
- Stateful services are `@Observable` classes (CullSession, ThumbnailCache)
- Models use `@Observable` + `Identifiable` + `Hashable` (by UUID)
- Async work uses structured concurrency (`TaskGroup`, `withTaskGroup`) with explicit batch sizes (8-16 for I/O, 4-8 for GPU)
- No Combine except for Sparkle's `CheckForUpdatesViewModel` and NotificationCenter publishers
- SQLite is used directly via `sqlite3_*` C API, not through an ORM or GRDB

## Reference

Key WWDC sessions for the underlying APIs:
- "Capture and Process ProRAW Images" (2021, session 10160) — RAW handling
- "Demystify SwiftUI Performance" (2023) — grid optimization
- "Images and Graphics Best Practices" (2018) — image downsampling
- "Optimize your Core ML usage" (2022) — Vision/ML profiling
- Apple sample project "Finding the Sharpest Image in a Sequence of Captured Images" — Accelerate blur detection (removed in favor of judging focus by eye; kept here as a pointer if it's ever revisited)
