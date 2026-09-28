# PhotoForge AI: Architecture, Plan and Risk Register

Status: design baseline v0.1 · Target: macOS 14+, Apple Silicon first · Language: Swift 6

This document covers the seven "begin by" deliverables in the spec:

1. System architecture diagram
2. Module-by-module plan
3. SQLite schema and migrations
4. Swift package structure
5. Roadmap
6. Sample code index
7. Risk register

The sample code lives in `Sources/`. `tools/reference_check.py` verifies the platform-neutral algorithms numerically.

---

## 1. System architecture

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│  PhotoForgeApp (SwiftUI + AppKit bridges)                                            │
│  Dashboard · All Photos · Albums/Smart Collections · People · Duplicates · Editor ·  │
│  Search · Privacy Dashboard · Activity Log      ── @Observable view models (MainActor) │
└───────────────┬───────────────────────────────┬───────────────────────────────┬──────┘
                │ async calls / AsyncStreams     │                               │
┌───────────────▼──────────┐   ┌────────────────▼─────────────┐   ┌─────────────▼──────────┐
│ PFJobs  (actor)          │   │ PFEditing                     │   │ PFSafety               │
│ priority queue, pause,   │   │ EditStack (JSON, versioned),  │◄──┤ GenerativeEditPolicy   │
│ cancel, retry, thermal / │   │ Core Image render graph,      │   │ request + output gates │
│ battery / memory aware   │   │ generative plumbing,          │   │ adult-workflow state   │
└──┬──────────┬────────────┘   │ provenance + XMP/C2PA export  │   └────────────────────────┘
   │ runs     │ runs           └──────────────┬────────────────┘
┌──▼────────┐ ┌▼──────────────────────┐        │ model calls
│ Indexing  │ │ Analysis jobs         │        │
│ jobs      │ │  hashes · quality ·   │        │
│ (metadata,│ │  faces · embeddings · │        │
│  deltas)  │ │  OCR · scene tags     │        │
└──┬────────┘ └──┬────────┬────────┬──┘        │
   │             │        │        │           │
   │   ┌─────────▼─────┐ ┌▼────────▼───────────▼────────────────────────┐
   │   │ PFSimilarity  │ │ PFVision                                      │
   │   │ pHash / dHash │ │ FaceDetector (Vision) → FaceAligner (5-point)  │
   │   │ BK-tree       │ │ ModelRegistry (licence / local / cloud gate)   │
   │   │ QualityMetrics│ │ CoreMLFaceEmbedder · scene & other runners     │
   │   │ DuplicateGroup│ │ EmbeddingBatcher (full ANE/GPU batches)        │
   │   │ BestShotScore │ └──────────────────────┬───────────────────────┘
   │   └───────┬───────┘                        │ face vectors
   │           │                    ┌───────────▼───────────────────────┐
   │           │                    │ PFPeople                          │
   │           │                    │ ConstrainedClusterer (Chinese     │
   │           │                    │ Whispers + must/cannot-link,      │
   │           │                    │ adaptive thresholds), review queue│
   │           │                    │ NeighborIndex (HNSW on disk)      │
   │           │                    └───────────┬───────────────────────┘
┌──▼─────────────▼──────────────────────────────────────────────────────────────────────┐
│ PFDatabase — GRDB DatabasePool (WAL) in ~/Library/Containers/…/Application Support     │
│ migrations · repositories · VectorCipher (AES-GCM, key in Keychain) · HNSW index files │
└──▲──────────────────────────────────────────────────────────────────────▲─────────────┘
   │ snapshots, deltas, pixels (read)                                       │ derivatives (write)
┌──┴──────────────────────────────────────────────────────────────────────┴─────────────┐
│ PFPhotosBridge — PhotoKit ONLY                                                          │
│ authorization · PHFetchResult streaming · PHCachingImageManager · persistent change     │
│ history (PHPersistentChangeToken) · PHAssetResourceManager (streamed SHA-256) ·          │
│ PHAssetCreationRequest (new derivative) · deleteAssets (behind DeletionConfirmation)     │
│ Optional: ReadOnlyLibraryInspector — copies metadata out of a user-chosen package        │
└─────────────────────────────────────────────────────────────────────────────────────────┘
        ▲ Apple Photos System Library (never written except via PhotoKit change requests)
```

**Invariants that hold throughout the codebase**

- **Photos access.** Nothing opens Apple's `Photos.sqlite` for writing. The optional inspector copies the package database to a temp file and reads the copy.
- **Pixels and biometrics stay on the Mac.** No pixels, embeddings, filenames, EXIF or GPS leave the device. Cloud runners exist only behind `ModelRegistry.setCloudEnabled(true)` and per-request consent.
- **Destructive actions.** Every deletion needs a `DeletionConfirmation` bound to the exact identifiers and count. Every deletion writes an `activity_log` row. PhotoKit adds its own system prompt and Recently Deleted on top.
- **Edits.** Edits are recipes, and source pixels are never overwritten. Exports to Photos create new assets unless the user explicitly chooses a PhotoKit content-editing replace.

---

## 2. Module-by-module implementation plan

| Module | Responsibility | Key Apple APIs | Sample code |
|---|---|---|---|
| **PFCore** | IDs, `IndexStage` bitmask, shared enums (mirroring the SQL CHECKs), errors | Foundation | `Sources/PFCore/Models.swift` |
| **PFDatabase** | GRDB pool, append-only migrations, repositories, sealed vector store, privacy wipes | GRDB, CryptoKit, Security | `AppDatabase.swift`, `Migrations/0001_initial.sql` |
| **PFPhotosBridge** | Authorization on user action; batched snapshot streaming; persistent-change deltas; iCloud-aware pixel loads; streamed original hashing; derivative export; confirmed deletion | Photos, AppKit | `PhotoLibraryService.swift` |
| **PFVision** | Orientation fix, face detection, landmarks, capture quality, 5-point ArcFace alignment; model registry; Core ML embedding runner; batcher | Vision, Core ML, Core Image, Accelerate | `FaceDetector.swift`, `EmbeddingPipeline.swift` |
| **PFSimilarity** | pHash/dHash, BK-tree, sharpness/noise/exposure, 4-tier grouping, explainable best-shot scoring | (pure Swift + CoreGraphics) | `PerceptualHash.swift`, `QualityMetrics.swift`, `DuplicateScoring.swift` |
| **PFPeople** | Constrained graph clustering, confidence labels, review queue, stable person IDs | — | `ConstrainedClustering.swift` |
| **PFJobs** | Priority scheduler, pause/resume/cancel, retry with back-off, thermal/battery/memory throttling, resumable progress | IOKit.ps, Dispatch | `JobManager.swift` |
| **PFEditing** | Versioned non-destructive `EditStack`, undo/redo/revert, generative records with disclosure, provenance | Core Image, Metal | `EditStack.swift` |
| **PFSafety** | Generative request/output gates, adult-workflow state, hard vs soft blocks | — | `GenerativeEditPolicy.swift` |
| **PFSearch** *(M5)* | Text→scene-embedding query plus FTS5 OCR plus structured filters, with an explanation per hit | Core ML, NaturalLanguage | — |
| **PFExport** *(M6)* | Formats, metadata keep/strip, GPS removal, XMP sidecars, optional C2PA manifest, presets | ImageIO, UniformTypeIdentifiers | — |

### Indexing pipeline (multi-stage and resumable)

| Stage | Bit | Work | Cost | Needs original? |
|---|---|---|---|---|
| 1 | `metadata` | PhotoKit snapshot → `assets` | ~0.1 ms/asset | no |
| 2 | `thumbnailHashes` | 512 px render → pHash, dHash, sharpness, noise, exposure | ~5–10 ms | no (uses cached derivative) |
| 3 | `faces` | Vision landmarks + capture quality + aligned crop | ~20–40 ms | no |
| 4 | `faceEmbeddings` | Batched Core ML (ANE) | ~1–3 ms/face batched | no |
| 5 | `sceneEmbedding`, `ocr` | Scene encoder, `VNRecognizeTextRequest` | ~10–30 ms | no |
| 6 | `fileHash` | Streamed SHA-256 of original | I/O bound | **yes**: only local originals by default, iCloud on user request |
| 7 | grouping | Duplicate grouper and face clusterer over the DB | seconds | no |

Each stage selects `WHERE analysisStage & bit = 0`, processes in bounded TaskGroups, and sets the bit per asset in a single write. A quit or crash therefore resumes exactly where it stopped. Incremental sync uses `fetchPersistentChanges(since:)`. Inserts and updates clear the relevant stage bits; deletes set `isDeletedInSource`. An expired token triggers a full reconcile that diffs local identifiers.

Timings are planning estimates for an M-series Mac and must be confirmed by the M2 benchmark suite.

### Duplicate tiers (each asset lands in exactly one group)

1. **Exact.** Same SHA-256 and same byte size. Deterministic.
2. **Near.** BK-tree radius query on pHash, confirmed by a second signal:
   - Tight: pHash ≤ 6 and dHash ≤ 10.
   - Loose: pHash ≤ 12 and scene-embedding cosine ≥ 0.95, which catches crops and watermarks.
3. **Burst.** Same PhotoKit `burstIdentifier`, or within 4 s with cosine ≥ 0.85.
4. **Similar.** Within 15 min with cosine ≥ 0.90. Uses seed-based (star) grouping so chains can't link unrelated photos.

The thresholds come from the reference run on natural-statistics (1/f) scenes:

| Change | pHash distance |
|---|---|
| Exposure change or sensor noise | ≤ 2 bits |
| ~6 % crop | median 6, p90 10 |
| Unrelated scenes | ≥ 20 bits |

Tune these against a labelled sample of real libraries in M3.

**Best shot.** The default weights are the spec's: technical 30, face 20, aesthetic 15, resolution 15, exposure 10, preference 10. Each factor is min-max normalised within the group. Factors with no data (for example, no faces) are dropped and their weight is redistributed. The explanation names the top factors where the winner leads by more than 0.1.

### People pipeline

Stages: Vision detect → quality filter (≥ 0.3) → align → embed → HNSW k-NN (k = 30) → graph → constrained Chinese Whispers → verification → review queue.

**Adaptive thresholds.** Each edge needs cosine ≥ 0.45, plus these penalties:

| Condition | Penalty |
|---|---|
| Lower-quality face in the pair | 0.15 × (1 − quality) |
| Face under 64 px | +0.05 |
| Frontal-vs-profile pair | +0.04 |

Each cluster then evicts members below max(0.45, μ − 3σ) of its own centroid-similarity distribution. Evicted faces go to review; they are never discarded.

**Constraints.** Constraints come from user feedback and override the algorithm:

- **Must-link.** Faces are collapsed into super-nodes before propagation.
- **Cannot-link.** Enforced during label adoption and re-verified afterwards.
- **"This is not [Person]".** Expands to cannot-links against that person's confirmed faces.
- **Confirmed persons.** Keep their IDs and can never be merged with each other.

**Confidence labels** describe cluster quality, not identity:

| Label | Condition |
|---|---|
| Confirmed | Only set by the user |
| Likely | μ ≥ 0.70 and ≥ 5 faces |
| Needs review | μ ≥ 0.55 |
| Low confidence | Otherwise |

Faces within 0.05 of two clusters are never auto-assigned.

---

## 3. SQLite schema and migration strategy

The full DDL is in `Sources/PFDatabase/Migrations/0001_initial.sql`. It was validated in SQLite: 19 tables, CHECK/UNIQUE/FK behaviour, cascades and FTS5.

It implements every table in the spec, plus five more that the requirements imply:

| Added table | Why it's needed |
|---|---|
| `source_libraries` | Multiple sources, and the stored PhotoKit change token |
| `face_constraints` | Must-link and cannot-link feedback as first-class data |
| `similarity_exclusions` | "Not similar" and "exclude from scans" |
| `activity_log` | The optional audit log, which never stores pixels, embeddings or GPS |
| `settings` | Privacy toggles (face analysis, crops, semantic index, location, cloud, adult workflow) |

**Design choices**

- **Enums** are TEXT with CHECK constraints, mirrored by Swift enums in `PFCore`, so bad writes fail loudly.
- **Hashes.** 64-bit pHash and dHash are stored as INTEGER by bit-casting `UInt64 ↔ Int64`. SHA-256 is a 32-byte BLOB.
- **Vectors** never sit in hot tables. `embeddings` holds the metadata, `embedding_vectors` holds AES-GCM-sealed Float32 blobs, and the HNSW index files live beside the DB, keyed by `vectorIndexName` and slot. The index can always be rebuilt from the sealed vectors.
- **GPS** is stored only when location indexing is on, and only as sealed BLOBs.
- **OCR** is an FTS5 table with `rowid = assets.id` (unicode61 with diacritic folding).
- **Indexes** cover PhotoKit identifier, creation date, file hash, pHash, burst, analysis stage, duplicate status, person membership, group membership, vector-index slot, and job status/priority.
- **Pragmas.** WAL, `synchronous=NORMAL`, `secure_delete=ON` (so deleted biometric rows are zeroed), and `VACUUM` after "Delete all face data".

**Migration strategy**

- GRDB `DatabaseMigrator` with append-only named migrations (`0001_initial`, `0002_…`). A shipped migration is never edited.
- Each migration runs in a transaction, and GRDB verifies foreign keys afterwards.
- Destructive changes (column drops, type changes) use SQLite's 12-step rebuild in a new migration.
- Before any migration, the app copies the DB to `Backups/<version>-<date>.sqlite`, keeping the last three copies.
- The `EditStack` JSON carries its own `version` and a forward `migrate()`. Recipes newer than the app are refused rather than half-read.
- CI opens fixture DBs from every previously shipped version and migrates them to head.
- Derived data (hashes, embeddings, clusters) can be invalidated by clearing stage bits instead of migrating, for example when the embedding model version changes.

---

## 4. Swift package and module structure

```
PhotoForge/
├── Package.swift                      # swift-tools 6.0, macOS 14, GRDB 7
├── PhotoForgeApp.xcodeproj            # (M0) app target, entitlements, signing, UI tests
├── Sources/
│   ├── PFCore/Models.swift
│   ├── PFDatabase/{AppDatabase.swift, Migrations/0001_initial.sql}
│   ├── PFPhotosBridge/PhotoLibraryService.swift
│   ├── PFVision/{FaceDetector.swift, EmbeddingPipeline.swift}
│   ├── PFSimilarity/{PerceptualHash.swift, QualityMetrics.swift, DuplicateScoring.swift}
│   ├── PFPeople/ConstrainedClustering.swift
│   ├── PFJobs/JobManager.swift
│   ├── PFEditing/EditStack.swift
│   └── PFSafety/GenerativeEditPolicy.swift
├── Tests/
│   ├── PFSimilarityTests/   hashing, BK-tree, quality, grouping, best-shot
│   ├── PFPeopleTests/       clustering, constraints, determinism
│   ├── PFDatabaseTests/     migrations, constraints, delete-all-face-data
│   └── PFEditingTests/      edit-stack serialization, undo/redo, safety policy
├── tools/reference_check.py # numeric verification of the algorithms (23 checks)
└── docs/ARCHITECTURE.md
```

**Dependency rule.** Feature modules depend only on `PFCore`. `PFEditing` also depends on `PFSafety`, and only `PFDatabase` depends on GRDB. The app target composes everything. This keeps the algorithm modules testable on CI without Photos access or entitlements.

**Distribution.** Everything runs as native Swift and Core ML. There is no embedded Python, so the app is sandbox-, notarization- and App Store-compatible.

Required entitlements:
- `com.apple.security.app-sandbox`
- `com.apple.security.personal-information.photos-library`
- `com.apple.security.files.user-selected.read-write` (for bookmarks)
- `com.apple.security.files.bookmarks.app-scope`

`Info.plist` needs `NSPhotoLibraryUsageDescription` and `NSPhotoLibraryAddUsageDescription`, each with a plain-language reason. Models are downloaded into the container after install, with SHA-256 pinning, and are signed-verified before loading.

---

## 5. Staged roadmap

Durations assume two engineers and are indicative only.

| Milestone | Scope | Exit criteria (from spec §13) |
|---|---|---|
| **M0 Foundations** (2 wk) | Xcode project, package, CI (build, test, SwiftLint), migrations, settings, privacy dashboard skeleton, activity log | Clean build on CI; migration fixtures pass |
| **M1 Photos browse** (3 wk) | Auth flow, streaming fetch, grid/list/timeline, thumbnail caching, inspector, persistent-change deltas, iCloud status | Browse 100k assets smoothly; Photos DB untouched (checked by a file-hash test) |
| **M2 Indexing engine** (3 wk) | JobManager, stage 2 hashes and quality, stage 6 file hash, pause/resume, throttling; benchmark harness (10k/100k synthetic) | UI stays at 60 fps while indexing; cancel/resume verified; memory bounded |
| **M3 Duplicates** (3 wk) | Grouper, comparison view, keep-best, review queue, confirmed PhotoKit delete, exclusions; threshold tuning on labelled data | Exact and near shown separately; nothing deleted without confirmation and audit |
| **M4 People** (4 wk) | Vision faces, model selection and licensing, Core ML embedder, HNSW index, clustering, review UI, merge/split/not-this-person, delete-all-face-data | Corrections respected on re-cluster; face data fully removable |
| **M5 Search** (3 wk) | Scene embeddings, OCR (FTS5), structured filters, smart collections, explanations | Queries return results with reasons |
| **M6 Editor** (5 wk) | Core Image adjustments, masks (Vision subject/person/sky), AI enhance tools, edit stack UI, export (XMP, GPS strip), derivative to Photos | Non-destructive and reversible; provenance stored |
| **M7 Generative and safety** (4 wk) | Inpaint/outpaint/removal runners, safety classifiers, policy gates, adult-workflow opt-in flow, C2PA (optional), abuse-case tests | Every generative layer labelled; all policy tests pass; red-team review signed off |
| **M8 Hardening** (3 wk) | 1M-face benchmark, accessibility, localisation, notarization, docs, threat-model review | Acceptance criteria met on the benchmark hardware matrix |

---

## 6. Sample code index (spec item 6)

| Requested sample | Where | Notes |
|---|---|---|
| PhotoKit authorization and asset fetching | `PFPhotosBridge/PhotoLibraryService.swift` | Batched, cancellable `AsyncThrowingStream`; persistent-change deltas; iCloud-aware loads; streamed SHA-256; confirmed delete |
| Vision face detection | `PFVision/FaceDetector.swift` | Landmarks and capture quality; orientation fix; ArcFace 5-point alignment (Umeyama closed form, reference residual 1e-14) |
| Embedding pipeline abstraction | `PFVision/EmbeddingPipeline.swift` | `ImageEmbeddingModel` protocol, `ModelRegistry` licence/cloud gate, Core ML runner with flip-TTA, `EmbeddingBatcher` actor |
| Perceptual hash calculation | `PFSimilarity/PerceptualHash.swift` | pHash bit-identical to imagehash's DCT definition (verified), dHash, BK-tree |
| Duplicate scoring | `PFSimilarity/DuplicateScoring.swift`, `QualityMetrics.swift` | 4-tier grouper, explainable weighted best-shot scorer |
| Background indexing job manager | `PFJobs/JobManager.swift` | Priorities, pause/resume, cancel, retry with back-off, thermal/battery/memory throttling, example `HashingJob` |
| *(bonus)* Constrained clustering, edit stack, safety policy, DB | `PFPeople`, `PFEditing`, `PFSafety`, `PFDatabase` | With tests |

---

## 7. Risk register

| # | Area | Risk | L | I | Mitigation |
|---|---|---|---|---|---|
| R1 | Photos compat | Apple changes the `Photos.sqlite` schema between macOS releases | H | M | PhotoKit is the primary path. The inspector is optional, read-only and works on a copy, with schema detection that disables it on unknown versions. Export/XMP fallback. |
| R2 | Photos compat | Persistent change token expires, or history is unavailable | M | M | Full reconcile by local-identifier diff; covered by tests |
| R3 | Photos compat | iCloud "Optimize Storage": originals not local | H | M | Stages 2–5 use PhotoKit derivatives. File hash is deferred to on-demand downloads the user started. "Downloading iCloud original" progress state. |
| R4 | Photos compat | Deletion via PhotoKit shows a system prompt and may be cancelled | H | L | Treat cancel as a no-op; record only confirmed outcomes |
| R5 | Licensing | **Most high-accuracy open face-recognition weights are non-commercial.** InsightFace model packs (e.g. buffalo_l) are licensed for non-commercial research. Many AdaFace/ArcFace checkpoints are trained on datasets with research-only terms. | H | H | Decide the distribution model in M4. Commercial builds need licensed weights (InsightFace offers commercial licences) or a model trained on licensed data. Personal builds can let the user download weights with the licence shown. `ModelRegistry` refuses non-commercial models in commercial builds. |
| R6 | Licensing | Generative model terms: SDXL uses CreativeML Open RAIL++-M (use restrictions); FLUX.1-dev is non-commercial; FLUX.1-schnell and LaMa are Apache-2.0 | M | H | Model inventory records licence and use restrictions; registry enforces them. Verify each licence at integration time. |
| R7 | Privacy | Face embeddings are biometric data (GDPR Art. 9, BIPA, and India's DPDP Act for Indian users) | M | H | Local-only, sealed at rest, off-switch, full wipe with VACUUM, no export of embeddings. Legal review before a commercial launch. |
| R8 | Privacy | Telemetry or crash logs leak filenames or GPS | M | H | No telemetry by default; crash reporter scrubs paths; CI lint for logging of sensitive fields |
| R9 | Safety | Non-consensual intimate imagery (NCII) or sexual deepfakes of real people | M | Critical | Hard "no escalation" rule: generative edits can't make a real person's photo more explicit. No face-swap, undress or age-transform tools exist in the API. Output gate runs after every generation. |
| R10 | Safety | Content involving minors | L | Critical | Hard block in the request, output and conventional-edit paths. Deliberately low minor threshold (0.2). Classifier scores are transient and never stored as person attributes. Red-team suite in M7. |
| R11 | Safety | Classifier false negatives or positives | M | H | Layered: prompt screen, then source classifier, then output classifier. Bias toward blocking on minors. Human-reviewable appeal path for soft blocks only. |
| R12 | Bias | Face recognition accuracy varies across demographics | M | H | Benchmark on a balanced, licensed evaluation set. Model card publishes per-group error rates. Conservative thresholds and the review queue limit harm from errors. No sensitive-trait inference. |
| R13 | Performance | 1M faces: graph and HNSW memory, Chinese Whispers runtime | M | M | Incremental clustering (assign new faces to existing centroids; full re-cluster offline). Memory-mapped HNSW. Benchmark gate in M8. |
| R14 | Performance | Generative models need a lot of memory (SDXL in fp16 alone is several GB) | H | M | Gate generative tools on RAM (≥ 16 GB recommended). Use Core ML compressed or palettized variants, VAE tiling, and unload after use. |
| R15 | Performance | Thermal throttling and battery drain during large scans | H | L | JobManager throttles on thermal state, Low Power Mode and battery; pause/resume |
| R16 | Data integrity | App DB corruption or failed migration | L | H | WAL, pre-migration backups, integrity check at launch, rebuild-from-source path |
| R17 | Distribution | App Store review of face recognition and adult features | M | M | Clear permission copy, privacy nutrition label. Adult workflow may need to be a notarized direct-download build only. Decide in M7. |
| R18 | Correctness | Duplicate thresholds tuned on synthetic data | H | M | Labelled real-world set (with consent) for tuning in M3. Precision-first defaults. The review queue means errors are never destructive. |

L = likelihood, I = impact.

---

## Changes from the first draft prompt

The earlier "AuraPhotos" prompt asked for four things this spec deliberately replaces:

- Parsing `Photos.sqlite` as the primary path
- An embedded Python engine
- InsightFace buffalo_l as a bundled model
- An "uncensored" pipeline with the safety checker stripped out

The replacements are:

- **PhotoKit first**, with a read-only inspector as an option (see R1).
- **Native Core ML**, which also makes the app sandbox- and notarization-compatible.
- **Licence-gated models** (see R5).
- **A local adult-content workflow for the user's own lawful media.** It keeps hard blocks against minors and against sexualising real people. These are the cases where "uncensored" causes real harm, and they can't be verified away by a settings toggle.
