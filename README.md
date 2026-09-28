# PhotoForge AI (working title)

A privacy-first macOS photo manager covering organization, duplicate cleanup, face grouping and non-destructive AI editing. It works with Apple Photos through PhotoKit, and all analysis runs on the Mac.

This is the **design baseline and core engine**. It is not a finished app yet. See `docs/ARCHITECTURE.md` for:

- The architecture diagram
- The module plan
- The schema and migration strategy
- The roadmap (M0–M8)
- The risk register

## What's here

| Path | Contents |
|---|---|
| `Package.swift` | Swift 6 package, macOS 14+, nine library modules + four test targets |
| `Sources/PFPhotosBridge` | PhotoKit auth, streaming fetch, persistent-change deltas, iCloud-aware loads, streamed SHA-256, derivative export, confirmed delete |
| `Sources/PFVision` | Vision face detection + capture quality, ArcFace 5-point alignment, model registry, Core ML embedder, batcher |
| `Sources/PFSimilarity` | pHash / dHash, BK-tree, sharpness / noise / exposure, 4-tier duplicate grouping, explainable best-shot scoring |
| `Sources/PFPeople` | Constrained Chinese Whispers clustering with must/cannot-link and adaptive thresholds |
| `Sources/PFJobs` | Background job manager: priorities, pause/resume, cancel, retries, thermal/battery/memory throttling |
| `Sources/PFEditing` | Versioned, non-destructive edit stack with generative provenance |
| `Sources/PFSafety` | Generative-edit and adult-workflow policy gates |
| `Sources/PFDatabase` | GRDB database, `Migrations/0001_initial.sql`, AES-GCM vector sealing, "delete all face data" |
| `Tests/` | Swift Testing suites for hashing, grouping, scoring, clustering constraints, migrations, edit-stack serialization, and the safety policy |
| `tools/reference_check.py` | Python port of the algorithms that verifies them numerically (23 checks) |

## Build

Requirements: Xcode 16+ (Swift 6), macOS 14+.

```bash
swift build
swift test          # Similarity, People, Editing/Safety and Database suites
python3 tools/reference_check.py   # needs numpy + scipy
```

The PhotoKit, Vision and Core ML code needs to run inside a signed app target with the Photos entitlement. Create `PhotoForgeApp.xcodeproj` in milestone M0 and add this package as a local dependency.

Required entitlements:
- `com.apple.security.app-sandbox`
- `com.apple.security.personal-information.photos-library`
- `com.apple.security.files.user-selected.read-write`
- `com.apple.security.files.bookmarks.app-scope`

`Info.plist` needs `NSPhotoLibraryUsageDescription` and `NSPhotoLibraryAddUsageDescription`.

## Models

No models are bundled. Each model is downloaded into the app container, pinned by SHA-256, and registered in `ModelRegistry` with its licence.

**Face-recognition licensing matters.** Popular pretrained face models (e.g. InsightFace packs) are licensed for non-commercial research only. Read risk R5 before choosing weights for a distributed build.

## Verification status

- **SQL schema:** validated in SQLite. Tables, CHECK/UNIQUE/FK constraints, cascades and FTS5 all behave as expected.
- **Algorithms:** pHash, BK-tree, quality metrics, alignment, grouping, scoring, clustering and the policy were verified by the Python reference (23/23 checks).
- **Swift sources:** written against the macOS 14 SDK but **not yet compiled**, because the authoring environment had no Swift toolchain. Expect to fix minor Swift 6 strict-concurrency diagnostics on the first build, most likely in the DispatchSource and NotificationCenter closures in `JobManager` and the PhotoKit callback bridging.
