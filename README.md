# PhotoForge

A private, on-device photo manager for macOS that works alongside Apple Photos. It finds duplicates, groups faces into people, and edits photos without ever touching your originals.

**Download:** [Latest release](../../releases/latest) → `PhotoForge-1.0.x.zip`
Universal app for Intel and Apple Silicon Macs. Requires **macOS 14 Sonoma or later**.

## Install

1. Download the zip from the latest release and double-click it to unzip.
2. Drag **PhotoForge.app** into your **Applications** folder.
3. **First launch only:** right-click (or Control-click) PhotoForge → **Open** → **Open**.
   macOS warns because the app isn't notarized with a paid Apple Developer ID. If there's no Open button, go to System Settings → Privacy & Security, scroll down, and click **Open Anyway**.
4. Click **Connect Apple Photos** and allow access.

Each new build is a new unsigned version, so macOS may ask for Photos permission again after an update.

## What it does

| Area | What you get |
|---|---|
| **Libraries** | Your System Photo Library (through Apple Photos), plus any other Photos library, iPhoto library or folder on the Mac or an external drive. Switch from the sidebar. Other libraries are read directly and **never modified**; PhotoForge reads a copy of their database. |
| **Library view** | Photos grouped into month or year sections, each with its own grid and a pinned header. Resizable, hideable preview pane. Favorites, screenshots, and a blurry-photo finder. ⌘-click to select several. |
| **iCloud** | Its own sidebar section: *iCloud Photos* (stored in iCloud, not downloaded to this Mac) and *Shared Albums*. "On This Mac" shows only what's stored locally. |
| **AI upscale to 2K** | **AI Fast** (FSRCNN) takes seconds, even on a 2015 MacBook. **AI Best** (Real-ESRGAN compact) is sharper and slower. Compare either against standard resizing at 100% on any part of the photo. Saves as a new photo or exports; the original is kept and the model used is recorded. Runs on the GPU through Metal via Core ML. |
| **Analysis** | A background scan you can pause, resume or stop. It slows down on battery or when the Mac is hot, and resumes where it left off after quitting. |
| **Duplicates** | Four separate kinds: *exact* (identical files), *near* (resized, re-saved or lightly edited copies), *burst* and *similar* shots. Side-by-side comparison with sharpness, exposure, noise, size and favorite status. An explained "Best" recommendation, plus "not similar" and "exclude" feedback that's remembered. |
| **Safe removal** | Nothing is deleted from the duplicates screen. Photos you don't keep go to a **Removal Queue**. Deleting from there needs your confirmation *and* Photos' own prompt, and moves photos to Recently Deleted (recoverable for 30 days). |
| **People** | Faces are detected and grouped on your Mac, and groups stay "Possible Person" until you name them. You can merge people, mark "Not this person" (remembered for future grouping), hide people, work through a review queue for uncertain faces, and adjust grouping strictness. |
| **Editor** | Non-destructive exposure, contrast, highlights, shadows, whites, blacks, temperature, tint, vibrance, saturation, clarity, dehaze, sharpening, noise reduction, vignette and grain, plus straighten, aspect crop and flip. Includes before/after and side-by-side views, undo/redo, and revert. **Save as New Photo** adds the edit to a "PhotoForge Edits" album and keeps the original. **Export** writes JPEG, HEIC, PNG or TIFF, with options to keep or strip metadata and remove location. |
| **Privacy** | Everything runs locally, with no network use and no analytics. Face data is encrypted at rest. One click deletes all face data, or all PhotoForge data. An optional activity log shows what the app did. |

## How accurate is it?

The build pipeline measures accuracy on every build:

- **Face grouping** uses OpenCV's **SFace** model (Apache-2.0), converted to Core ML and verified against the original to cosine 1.000000.
  - On a Labeled Faces in the Wild sample (12 people, 96 photos), it told same and different people apart with **100% pairwise accuracy**.
  - Grouping ran at **100% precision**. Uncertain faces go to the review queue instead of being guessed.
- **Duplicate detection:**
  - Perceptual hashes ignore exposure changes (0 bits moved in the self-test) and separate different scenes by 20+ bits.
  - Exact duplicates are confirmed by SHA-256 of the original files.
  - "Similar shot" grouping uses Apple Vision feature prints with deliberately high thresholds. Tune it with **Settings › Matching strictness**.

### Reading other libraries

Apple's Photos framework only gives apps access to the *System* Photo Library, so PhotoForge reads other libraries directly from their files:

- **Photos libraries (macOS 10.15+):** the database is copied, and the copy is read. Photos whose originals are only in iCloud are shown from the library's own preview files.
- **iPhoto and older Photos libraries:** read as a folder of image files (their `Masters` folder), using camera dates from the photos' EXIF data.
- **Any folder:** every image inside, including RAW, HEIC and PNG files.

Deleting and saving edits back only work for the System Photo Library. For other libraries, use **Export**.

If macOS blocks access to a library, add PhotoForge under System Settings › Privacy & Security › Full Disk Access.

## Not in this version

- **AI generative editing** (inpainting, outpainting, object removal). It needs large diffusion models that are impractical on Intel Macs. The safety policy for it is already implemented and tested (`PFSafety`).
- **Natural-language search**, OCR search, and videos in duplicate detection.
- **Notarized, Keychain-backed builds.** These need an Apple Developer ID. For ad-hoc builds, the face-data encryption key is stored in a protected file (0600 permissions) in the app's data folder, because the Keychain would prompt after every update.

## For developers

```
Package.swift                 Swift 6 toolchain, Swift 5 language mode; 9 library modules + app
Sources/PF*                   engine modules (see docs/ARCHITECTURE.md)
Sources/PhotoForgeApp         SwiftUI app, analysis job, self-test and face-calibration modes
scripts/package_app.sh        universal .app + zip (ad-hoc signed)
tools/convert_sface.py        SFace ONNX → Core ML, verified against ONNX Runtime
tools/lfw_sample.py           CI-only face calibration set (never shipped)
.github/workflows/build.yml   build → 31 unit tests → package → self-test (arm64 + x86_64) → face calibration → release
```

Every push to `main` runs the full pipeline on a GitHub-hosted Mac. A release is published only if the build, the tests and the packaged-app self-test all pass. Logs are pushed to the `ci-results` branch.

Build locally with Xcode 16+ using `swift build`, `swift test`, and `scripts/package_app.sh`. Run `PhotoForge.app/Contents/MacOS/PhotoForge --selftest` to check an installed copy.
