# Building a macOS photo culling app in Swift is highly feasible

**A Narrative Select–style photo culling app can be built almost entirely with Apple's native frameworks.** The critical path — RAW preview extraction, keyboard-driven UI, blur detection, and shot grouping — maps cleanly onto ImageIO, Vision, Metal Performance Shaders, and SwiftUI APIs that ship with macOS. Only two features require meaningful third-party effort: aesthetic quality scoring (Core ML model conversion) and robust XMP sidecar writing (no Apple API covers the full spec). On Apple Silicon, the entire analysis pipeline — thumbnail extraction, face detection, blur scoring, and feature-print generation — processes **~20–55ms per photo**, meaning a 2,000-image shoot can be fully analyzed in under two minutes.

---

## RAW preview extraction is effectively a solved problem

Apple's **ImageIO** framework supports every major RAW format natively: CR2, CR3, ARW, NEF, DNG, RAF, and ORF. The key insight for performance is that nearly all RAW files embed full-resolution JPEG previews (the same image shown on the camera LCD), and ImageIO can extract these without triggering a RAW demosaic.

The critical API is `CGImageSourceCreateThumbnailAtIndex` with the option `kCGImageSourceCreateThumbnailFromImageIfAbsent`. When an embedded preview exists — which it does in virtually all camera RAW files — this function extracts and downscales the JPEG in **~15–50ms per file** on Apple Silicon. Compare this to full RAW decoding via `CIRAWFilter`, which takes **~3 seconds** on first invocation (Metal shader compilation) and ~50–200ms on subsequent calls. The embedded preview path is 10–100× faster.

For the dual import mode specifically, the architecture is straightforward. Scan the import directory for RAW+JPEG pairs by matching basenames. Display the sidecar JPEG or extracted embedded preview in the grid. Only invoke `CIRAWFilter` when the user opens a single image for detailed inspection. The `CIRAWFilter.previewImage` property (macOS 12+) also provides the embedded preview as a `CIImage`, but `CGImageSourceCreateThumbnailAtIndex` is faster for bulk thumbnail generation because it avoids Core Image pipeline overhead.

**CR3 format support** arrived in macOS Catalina (10.15), but each specific Canon camera model requires Apple to add support incrementally. There is a known issue in macOS Sequoia 15.1 where CR3 files with HDR PQ–enabled HEVC previews cause excessive CPU usage in the system's `ImageThumbnailExtension` process. DNG has basic support even for unlisted cameras, making it a reliable fallback. Apple maintains a current list of supported RAW cameras that covers iOS 18, macOS Sequoia 15, and visionOS 2.

**Difficulty: Easy.** Built-in APIs handle everything. Development estimate: 1–2 weeks for the RAW+JPEG pair manager and thumbnail extraction pipeline.

---

## Keyboard-driven culling maps well onto SwiftUI's focus system

SwiftUI on macOS 14 (Sonoma) introduced `.onKeyPress`, the native modifier for handling keyboard input without AppKit bridging. It supports filtering by specific keys, character sets, and key phases (down, up, repeat), and returns `.handled` or `.ignored` to control event propagation. For a culling app, the mapping is direct:

```swift
.onKeyPress(keys: ["p"]) { _ in markAsPick(); return .handled }
.onKeyPress(keys: ["x"]) { _ in markAsReject(); return .handled }
.onKeyPress(characters: .decimalDigits) { press in
    if let digit = Int(press.characters), (1...5).contains(digit) {
        setRating(digit); return .handled
    }
    return .ignored
}
.onKeyPress(.rightArrow) { _ in nextPhoto(); return .handled }
```

**The critical requirement is that the view must be both `.focusable()` and `.focused()`.** This is the number-one debugging issue developers encounter — if no view has focus, `onKeyPress` never fires. Apply `.focusable()` *before* `.focused($isFocused)`, set focus on appear (sometimes requiring a short `DispatchQueue.main.asyncAfter` delay), and use `.focusEffectDisabled()` to suppress the blue focus ring that macOS draws around focused views.

For apps that must support macOS versions prior to Sonoma, `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` remains viable. This intercepts key events at the window level regardless of which SwiftUI view has focus, which is actually advantageous for a culling app where keyboard shortcuts should work globally. The tradeoff is that it bypasses SwiftUI's declarative event handling.

Three SwiftUI-specific gotchas deserve attention. First, focus can be lost when the user clicks other UI elements like sidebars or toolbars — the viewer must reclaim focus programmatically. Second, mixing AppKit views via `NSViewRepresentable` can cause focus to get "stuck" because SwiftUI's focus system doesn't perfectly map to AppKit's first-responder chain. Third, on macOS, Tab and Shift+Tab navigate focus between focusable views only when "Use keyboard navigation" is enabled in System Preferences — keep the number of focusable views minimal to avoid confusing tab behavior.

**Difficulty: Easy to moderate.** The core keyboard handling is straightforward; edge cases around focus management require testing. Development estimate: 1–2 weeks.

---

## XMP sidecars require careful schema work but no third-party libraries

XMP sidecar files are XML documents following Adobe's XMP specification. The core metadata for a culling app uses the `xmp:` namespace (`http://ns.adobe.com/xap/1.0/`):

- **Star ratings**: `xmp:Rating` as an integer, values **0–5** (0 = unrated, 1–5 = star ratings, **-1 = rejected** in Adobe Bridge)
- **Color labels**: `xmp:Label` as text — Lightroom uses `"Red"`, `"Yellow"`, `"Green"`, `"Blue"`, `"Purple"`
- **Pick/reject flags**: **Not stored in XMP at all.** Lightroom's pick/reject flags exist only in the Lightroom catalog database and are never exported to sidecar files. This is a critical discovery for cross-app compatibility — use `xmp:Rating = -1` for Bridge-compatible reject, or a specific color label like `"Red"` to indicate rejection in a Lightroom-importable way.

A minimal valid XMP sidecar file is surprisingly small:

```xml
<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
   xmp:Rating="3"
   xmp:Label="Green"
   xmp:CreatorTool="MyCullingApp 1.0">
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>
```

Writing this in Swift requires no dependencies — a string template with interpolated values works perfectly. For reading, macOS provides `XMLDocument` with XPath support, making it trivial to parse existing sidecars. Apple also provides `CGImageMetadataCreateFromXMPData` and `CGImageMetadataCreateXMPData` for converting between XMP byte streams and structured metadata objects, though these APIs are documented inconsistently and developers report that "custom tags just disappear" when round-tripping through them.

**File naming matters for compatibility.** Use `<basename>.xmp` (e.g., `IMG_1234.xmp`) for Lightroom compatibility. darktable uses `<basename>.<extension>.xmp` (e.g., `IMG_1234.CR3.xmp`) and will read Lightroom-format sidecars on import but never write to them. For maximum cross-app compatibility, write `<basename>.xmp` files and let darktable create its own parallel sidecars. Always read existing sidecars before writing to avoid clobbering Camera Raw develop settings that Lightroom may have stored.

**Difficulty: Moderate.** The schema is well-documented but the pick-flag gap and cross-app compatibility require careful design decisions. Development estimate: 1–2 weeks.

---

## Blur detection has a fast GPU path and a smart hybrid architecture

The most effective blur detection strategy for a photo culling app combines two complementary approaches: **Metal Performance Shaders for global sharpness** and **Vision framework for face-specific quality**.

**The MPS Laplacian path is the fastest option.** `MPSImageLaplacian` applies an optimized Laplacian edge-detection kernel on the GPU, and `MPSImageStatisticsMeanAndVariance` computes the variance of the result via GPU reduction, outputting a 2×1 pixel texture containing mean and variance. The entire pipeline — source texture → Laplacian → variance — executes in **~1–5ms on Apple Silicon** for typical photo resolutions. Sharp images produce high Laplacian variance; blurry images produce low variance. This classic approach (Pech-Pacheco et al., 2000) detects defocus blur excellently, handles motion blur moderately well, but struggles with intentional bokeh where sharp subjects coexist with blurred backgrounds.

**Apple's `VNDetectFaceCaptureQualityRequest`** (macOS 10.15+) solves the bokeh problem for portrait photography. It returns a **0.0–1.0 quality score** per detected face, incorporating sharpness, lighting, pose, expression, and eye openness into a single trained metric. This is essentially Apple's built-in "best face" selector. It takes **~5–15ms per image** and handles the exact scenario where global Laplacian variance fails: a perfectly sharp portrait with creamy bokeh.

The recommended hybrid architecture runs both in parallel:

1. Extract embedded JPEG preview, downscale to ~512px
2. Run `VNDetectFaceCaptureQualityRequest` → face quality scores (if faces exist)
3. Run `MPSImageLaplacian` → `MPSImageStatisticsMeanAndVariance` on the full image or face-cropped regions
4. Combine scores: face quality + Laplacian variance → composite quality metric
5. Optionally run a NIMA Core ML model for aesthetic quality scoring

For blink detection specifically, Vision framework has no dedicated API, but `VNDetectFaceLandmarksRequest` returns 76-point face landmarks including full eye contours. Computing the **Eye Aspect Ratio** (EAR = vertical eye distance / horizontal eye distance) from these landmarks detects closed eyes reliably — open eyes have EAR ≈ 0.2–0.3, closed eyes drop below 0.2. The legacy `CIDetector` also exposes `CIFaceFeatureLeftEyeClosed` and `CIFaceFeatureRightEyeClosed` booleans, though with lower accuracy.

An alternative CPU path uses Apple's Accelerate framework: `vImageConvolve_PlanarF()` applies the Laplacian kernel, and `vDSP_normalize()` computes the standard deviation. Apple provides an official sample project, "Finding the Sharpest Image in a Sequence of Captured Images," demonstrating this exact approach. It's SIMD-optimized on Apple Silicon and runs in **~2–10ms** per image.

For aesthetic quality beyond blur/sharpness, the **PhotoAssessment** project on GitHub provides a pre-converted NIMA (Neural Image Assessment) Core ML model that scores images on a 1–10 quality scale. MobileNet-based NIMA inference takes **~2–5ms** on the Neural Engine. More sophisticated models like MUSIQ exist but require complex Core ML conversion due to variable input sizes and custom position encodings.

**Difficulty: Easy for basic blur detection** (MPS path is ~20 lines of code), **moderate for the full hybrid pipeline**, **hard for aesthetic quality scoring** (model conversion and threshold tuning). Development estimate: 2–4 weeks for the complete quality assessment system.

---

## Shot grouping works best with temporal clustering plus Vision feature prints

The most production-proven approach, validated by the ShutterSlim app (which reached #2 in the German App Store processing 35,000-photo libraries), combines EXIF timestamp clustering with Apple's `VNGenerateImageFeaturePrintRequest` for visual similarity.

**Step 1: Temporal clustering.** Read `kCGImagePropertyExifDateTimeOriginal` via `CGImageSourceCopyPropertiesAtIndex` (~2–4ms per file, no pixel decoding). Sort by timestamp and cluster using a simple gap threshold. A **10-minute gap** works well for grouping shots from a photo shoot — in ShutterSlim's testing on 35,000 photos, this produced ~5,300 clusters with a median size of 2–3 photos. For burst-shot detection specifically, a 1–5 second threshold identifies rapid-fire sequences.

**Step 2: Visual similarity within time clusters.** `VNGenerateImageFeaturePrintRequest` generates a dense semantic embedding per image. The critical implementation detail is that **Revision 2** (macOS 14+) produces normalized **768-dimensional** vectors with distances in the 0.0–~2.0 range, while **Revision 1** (macOS 10.15+) produces **2048-dimensional** unnormalized vectors with distances in the 0.0–~40.0 range. Production-tested threshold for Revision 2: **~0.35** for near-duplicate grouping. The `computeDistance(_:to:)` method uses Euclidean distance internally (confirmed by framework decompilation).

Feature print generation takes **~15–50ms per image** on Apple Silicon — the neural network inference is the bottleneck. For 2,000 images, expect ~30–100 seconds for initial generation, but results should be cached to SQLite or Core Data keyed by photo ID and modification date. Subsequent launches only process new images.

For a fast pre-filter, **dHash (difference hash)** identifies exact duplicates in under 1ms per image. The CocoaImageHashing library provides a native Swift implementation supporting dHash, pHash, and aHash with built-in data parallelism. A Hamming distance threshold of **2 bits** (128-bit hash) catches compression and resize variants with minimal false positives. This catches trivially identical images before the heavier Vision pipeline runs.

**CLIP embeddings via Core ML are overkill for duplicate detection.** Apple's own MobileCLIP models are available pre-converted on HuggingFace (`apple/coreml-mobileclip`) and run at 3–10ms per image, but they add 11–173MB to app size and provide cross-modal understanding (text↔image) that a culling app doesn't need. VNFeaturePrintObservation achieves comparable visual similarity detection with zero dependencies.

**Difficulty: Moderate.** The temporal clustering is trivial. Feature print generation and threshold tuning require experimentation. Caching adds implementation surface. Development estimate: 2–3 weeks.

---

## The thumbnail pipeline needs a three-tier cache and careful memory management

Displaying 1,000–2,000 RAW thumbnails smoothly in a SwiftUI `LazyVGrid` is achievable but requires deliberate architecture. The recommended approach uses three tiers:

**Tier 1 — In-memory cache** via `NSCache` with a 500-item count limit and 100MB total cost limit. `NSCache` is thread-safe and auto-evicts under memory pressure. This serves thumbnails for visible and recently-visible cells.

**Tier 2 — Disk cache** storing generated thumbnails as JPEG files (~20–50KB each at 0.7 quality, 400px) in the app's Caches directory, keyed by a hash of the source file URL. This survives app restarts.

**Tier 3 — On-demand extraction** via `CGImageSourceCreateThumbnailAtIndex` from the original RAW file. Use `TaskGroup` with 8–16 concurrent tasks for parallel generation across Apple Silicon's performance cores.

Realistic benchmarks on M-series chips for 1,000 RAW files:

| Operation | Per image | 1,000 images (8-way parallel) |
|-----------|-----------|-------------------------------|
| EXIF metadata read | 2–4ms | ~0.3–0.5s |
| Embedded JPEG preview (400px) | 15–50ms | **~2–6s** |
| Full RAW decode (CIRAWFilter) | 50–3,000ms | Minutes (impractical) |
| QLThumbnailGenerator (cached) | <5ms | <1s |

**LazyVGrid handles 1,000+ items smoothly** when cell views are simple, but it has a critical difference from UICollectionView: **it does not implement cell reuse**. Images loaded into cells that scroll off-screen remain in memory. The fix is explicit: set the image to `nil` in `.onDisappear` and reload in `.task`. Use `kCGImageSourceShouldCache: false` when creating image sources to prevent ImageIO from retaining full decoded images. The `.task` modifier on SwiftUI views automatically cancels when the view disappears, preventing wasted work for cells that scroll off-screen before loading completes.

For progressive rendering, show a gray placeholder immediately, then the low-resolution embedded thumbnail (~128px, extracted in ~5ms), then the full-quality thumbnail (~512px). `QLThumbnailGenerator.generateRepresentations(for:update:)` provides this natively with three quality tiers (icon → low-quality → full), but direct `CGImageSourceCreateThumbnailAtIndex` is faster for bulk RAW processing because it avoids IPC overhead (QLThumbnailGenerator runs out-of-process).

**Difficulty: Moderate.** The individual pieces are straightforward, but making the full pipeline feel instant and managing memory correctly across thousands of images requires careful engineering. Development estimate: 2–3 weeks.

---

## What's easy, what's moderate, and what's hard

| Feature | Difficulty | Dependencies | Dev estimate | Key APIs |
|---------|-----------|-------------|-------------|----------|
| RAW preview extraction | **Easy** | None (built-in) | 1–2 weeks | `CGImageSourceCreateThumbnailAtIndex`, `CIRAWFilter.previewImage` |
| Keyboard culling UI | **Easy–Moderate** | None | 1–2 weeks | `.onKeyPress` (macOS 14+), `@FocusState`, `.focusable()` |
| XMP sidecar read/write | **Moderate** | None | 1–2 weeks | `XMLDocument`, string templates, `CGImageMetadataCreateFromXMPData` |
| Global blur detection | **Easy** | None | 1 week | `MPSImageLaplacian`, `MPSImageStatisticsMeanAndVariance` |
| Face quality scoring | **Easy** | None | 3–5 days | `VNDetectFaceCaptureQualityRequest` |
| Blink detection | **Moderate** | None | 1 week | `VNDetectFaceLandmarksRequest` + EAR calculation |
| Near-duplicate detection | **Moderate** | None | 2–3 weeks | `VNGenerateImageFeaturePrintRequest`, `computeDistance` |
| Shot/scene grouping | **Moderate** | None | 2–3 weeks | EXIF timestamp clustering + feature print similarity |
| Thumbnail pipeline | **Moderate** | None | 2–3 weeks | `CGImageSource`, `NSCache`, `LazyVGrid`, `TaskGroup` |
| Aesthetic quality scoring | **Hard** | Core ML model (PhotoAssessment/NIMA) | 2–4 weeks | `coremltools` conversion, `MLModel` inference |
| CLIP-based features | **Hard** | MobileCLIP model (~11–173MB) | 3–4 weeks | `apple/coreml-mobileclip` from HuggingFace |

**Total estimated development time for a competent Swift developer: 12–20 weeks** for a full-featured MVP, with the core culling workflow (import, display, keyboard-flag, export XMP) achievable in 4–6 weeks.

---

## Gotchas and recommendations that will save you weeks

**The pick-flag gap is the biggest workflow surprise.** Lightroom's pick/reject flags are catalog-only and never appear in XMP. Design the app to use `xmp:Rating = -1` for Adobe Bridge–compatible rejection, and document that Lightroom users should use color labels or star ratings as their pick/reject signal. This is a user-education issue, not a technical one.

**VNFeaturePrint revision differences can silently break duplicate detection.** Revision 1 (macOS 10.15–13) produces 2,048-float vectors with distances ~0–40; Revision 2 (macOS 14+) produces 768-float normalized vectors with distances ~0–2. Thresholds from one revision are meaningless for the other. Pin to a specific revision with `request.revision` or detect the OS version and adjust thresholds accordingly.

**CR3 files with HDR PQ cause known system issues** on macOS Sequoia 15.1, triggering excessive CPU usage in `ImageThumbnailExtension`. Test with Canon R5 Mark II files specifically.

**SwiftUI's focus system is fragile on macOS.** Invest in a robust focus management layer early — create a single "keyboard target" view that always reclaims focus after any UI interaction. Consider keeping `NSEvent.addLocalMonitorForEvents` as a fallback even if targeting macOS 14+.

**Cache feature prints aggressively.** Neural network inference at ~15–50ms per image is the most expensive per-image operation in the pipeline. Store feature print vectors in SQLite (768 floats × 4 bytes = ~3KB per image, or ~6MB for 2,000 images). Re-scan only processes new or modified files.

**Key WWDC sessions for reference**: "Capture and Process ProRAW Images" (2021, session 10160) for RAW handling; "Demystify SwiftUI Performance" (2023) for grid optimization; "Images and Graphics Best Practices" (2018) for image downsampling; "Optimize your Core ML usage" (2022) for Vision/ML profiling. The Apple sample project "Finding the Sharpest Image in a Sequence of Captured Images" provides a complete Accelerate-based blur detection implementation.

The bottom line: **every core feature of a Narrative Select competitor can be built with zero third-party dependencies** using ImageIO, Vision, MPS, Core Image, and SwiftUI. The only feature that benefits from an external model is aesthetic quality scoring (NIMA via Core ML), and even that has an open-source pre-converted model available in the PhotoAssessment GitHub project.