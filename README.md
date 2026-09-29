# PhotoForge

A private, on-device photo and video manager for macOS. Use it with Apple Photos, or keep your own PhotoForge libraries on any drive. It finds duplicates, groups faces into people, plays almost any video format, and edits photos without ever touching your originals.

**Download:** [Latest release](../../releases/latest) → `PhotoForge-1.0.x.zip`
Universal app that runs natively on Intel Macs and on every Apple silicon Mac (M1, M2, M3, M4, M5). Requires **macOS 14 Sonoma or later**, which every Apple silicon Mac can run.

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
| **Libraries** | As many libraries as you like, each with **its own database**, switchable from the sidebar without restarting. **Apple Photos** (through Photos). **PhotoForge Libraries**: your own library on any drive, independent of Apple Photos. Drag in or import photos and videos; duplicates are skipped. It can **copy your Apple Photos library** into one, carrying over names, categories, faces and people so nothing is rescanned. **Other Photos/iPhoto libraries and folders** are read directly and never modified. |
| **Keeps your work** | Library data lives outside the app. Installing a new version never needs a rescan, and the database is backed up automatically before an upgrade. Move a library's data to another drive, back up and restore from Settings. See [docs/LIBRARY_FORMAT.md](docs/LIBRARY_FORMAT.md). |
| **Names & albums** | Rename one photo or thousands at once, by pattern (`Farm Visit {date} {n}`), find & replace, or prefix/suffix. Sort and **group by name**. In a PhotoForge Library the files are renamed too; in Apple Photos the name can also be written as the photo's Title. **My Albums**: your own albums and folders in any library. |
| **Videos** | A **Videos** section, duration badges, and a player window. Apple's hardware-accelerated player handles MP4/MOV/M4V; the bundled **VLC engine** plays everything else (MKV, AVI, WMV, FLV, WebM, MPEG-TS, 3GP, …). |
| **This Mac** | On first launch (and if the hardware changes) PhotoForge checks the processor, cores, memory, GPU and Neural Engine and tunes itself: parallel analysis, text-recognition accuracy, image sizes, thumbnail cache, and whether AI runs on the Neural Engine. Settings › This Mac shows the result, with a Battery saver / Maximum speed override. |
| **Sharing with other apps** | An optional, read-only, token-protected API on this Mac only, so other software can use a library with your permission. See [docs/API.md](docs/API.md). |
| **Library view** | Photos grouped into month or year sections, each with its own grid and a pinned header. Resizable, hideable preview pane. Favorites, screenshots, and a blurry-photo finder. ⌘-click to select several. |
| **Categories** | Documents, Receipts & Bills, Screenshots, WhatsApp, Social Media, QR & Barcodes and Camera Photos, from Apple's on-device image classification, page detection, text recognition and barcode detection, plus file names and camera data. Each photo shows *why* it's in a category, and you can add or remove it (remembered). **Search** finds text inside photos (e.g. an invoice number) and file names. |
| **Folders & Albums** | An expandable sidebar tree: your Photos albums, folders and smart albums; the folder hierarchy of iPhoto libraries and folders; albums of other Photos libraries; otherwise Year › Month. |
| **Slideshow** | Full-screen slideshow of any view (folder, album, category, person, search results) or of the selected photos. Crossfades, ←/→, Space, interval, shuffle, repeat, Esc to exit. |
| **Windows** | The editor and upscaler open as separate windows that stay on top (pin button to release), size themselves to your screen, and fold the adjustment panel over the photo when the window is narrow. |
| **iCloud** | Its own sidebar section: *iCloud Photos* (stored in iCloud, not downloaded to this Mac) and *Shared Albums*. "On This Mac" shows only what's stored locally. |
| **AI upscale to 2K** | Upscale to 2K (2048 px) or Full HD with **AI Detail** (FSRCNN, recommended) or **AI Strong** (Real-ESRGAN, for very small or soft images). Compare against standard resizing at 100% on any part of the photo. Saves as a new photo or exports; the original is kept and the model used is recorded. Runs on the GPU through Metal via Core ML. |
| **Analysis** | A background scan you can pause, resume or stop. It slows down on battery or when the Mac is hot, and resumes where it left off after quitting. |
| **Duplicates** | Two groups in the sidebar: **Exact Duplicates** (identical files) and **Near Duplicates** (resized, re-saved or lightly edited copies), with **Burst Shots** and **Similar Shots** as sub-sections of Near Duplicates. Side-by-side comparison with sharpness, exposure, noise, size and favorite status. An explained "Best" recommendation, plus "not similar" and "exclude" feedback that's remembered. |
| **Safe removal** | Nothing is deleted from the duplicates screen. Photos you don't keep go to a **Removal Queue**. Deleting from there needs your confirmation *and* Photos' own prompt, and moves photos to Recently Deleted (recoverable for 30 days). |
| **People** | Faces are detected and grouped on your Mac, and groups stay "Possible Person" until you name them. **Tag faces yourself**: in the preview pane turn on *Show & tag faces*, click a face and type a name, or drag a box around a face that was missed. PhotoForge immediately gathers that person's other photos and offers "Is this …?" suggestions to accept or reject. Settings › Face data lets you rename, merge or delete people and re-detect faces. You can merge people, mark "Not this person" (remembered for future grouping), hide people, work through a review queue for uncertain faces, and adjust grouping strictness. |
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

### Upscaling quality

Measured by the build pipeline on 24 real photos. Each photo was shrunk and then brought back to its original size:

| Method | ×2 fidelity (PSNR) | ×2 sharpness vs original | ×4 fidelity | ×4 sharpness |
|---|---|---|---|---|
| AI Detail (FSRCNN) | **37.1 dB** | **99%** | **29.4 dB** | 56% |
| AI Strong (Real-ESRGAN) | 28.0 dB | 578% (over-sharpened) | 26.0 dB | 235% |
| Standard (Lanczos) | 36.5 dB | 70% | 28.6 dB | 26% |

FSRCNN is the most faithful and restores sharpness. Real-ESRGAN adds strong synthetic detail, so compare before saving. On an Intel Mac, FSRCNN takes about a second per photo; Real-ESRGAN can take a minute or more for large photos.

## Not in this version

- **AI generative editing** (inpainting, outpainting, object removal). It needs large diffusion models that are impractical on Intel Macs. The safety policy for it is already implemented and tested (`PFSafety`).
- **Natural-language search**, and videos in duplicate detection or face grouping.
- **macOS 13 and older.** The app uses frameworks introduced in macOS 14. Every Apple silicon Mac (M1–M5) can run macOS 14 or later.
- **Notarized, Keychain-backed builds.** These need an Apple Developer ID. For ad-hoc builds, the face-data encryption key is stored in a protected file (0600 permissions) in the app's data folder, because the Keychain would prompt after every update.

## Third-party components

- **VLCKit** (VideoLAN), LGPL-2.1, is bundled unmodified as a dynamic framework in `PhotoForge.app/Contents/Frameworks`. Its source code is at https://code.videolan.org/videolan/VLCKit.
- **SFace** (OpenCV Zoo), **FSRCNN** and **Real-ESRGAN compact** models are converted to Core ML at build time.
- **GRDB** (MIT) is used for the database.

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
