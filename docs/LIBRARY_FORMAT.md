# Library and data format

## Where data lives

```
~/Library/Application Support/PhotoForge/
  Libraries.json            list of your libraries (name, kind, where its data is, last opened)
  photoforge.sqlite         Apple Photos library data (+ vector.key, FaceCrops/, Backups/)
  Libraries/<uuid>/         data for each other library you opened read-only (same layout)
  api-tokens.json           hashed API tokens (0600)
```

A **PhotoForge Library** keeps everything in one package, so it can live on any drive and be opened on another Mac:

```
Farm Photos.pflibrary/
  Library.json              {format, id, name, created, createdBy}
  Database/                 photoforge.sqlite, vector.key, FaceCrops/, Backups/
  Originals/YYYY/MM/        imported photos and videos (never modified)
  Edits/                    edited and upscaled copies
  Trash/                    deleted items, until you empty it
```

Double-click a `.pflibrary` in Finder, or use File › Open Library, to open it.

## Upgrades never rescan

The databases live outside the app, so installing a new version keeps everything:

- **Analysis.** Hashes, categories, recognised text, faces, people, names and albums are all kept.
- **Backups.** Before a new version changes a database's structure, PhotoForge saves a copy in `Backups/`. It keeps the last few copies. You can also back up, or restore from a backup, in Settings › Libraries.
- **Older data.** Earlier versions kept all libraries in one file. On first launch, the new version splits that file into one database per library. The split carries all existing data over and makes a backup first.

## Database (SQLite, WAL mode)

The main tables are below. Ids are integers. Dates are Unix seconds (REAL).

| Table | Contents |
|---|---|
| `source_libraries` | The library this database describes |
| `assets` | One row per photo or video. `localIdentifier` is the key in its library: a PhotoKit id, `pkg:<uuid>` / `file:<path>` for read-only libraries, or `pf:<uuid>` for a PhotoForge Library. Other columns: `mediaType` (image/video), `creationDate`, `pixelWidth`, `pixelHeight`, `duration`, `favorite`, `title` (the name you gave it), `originalFilename`, `filePath` (relative to the package), `fileSize`, `fileHash` (SHA-256), `perceptualHash`, `differenceHash`, `sharpnessScore`, `noiseScore`, `exposureScore`, `isDeletedInSource` |
| `asset_categories` | `assetID`, `category`, `confidence`, `reason`, `source` (auto/user) |
| `ocr_text` | Full-text index of text found in photos (`rowid` = asset id) |
| `pf_albums` / `pf_album_members` | Your albums and folders (`parentID` nests them), and which items are in each |
| `faces` | `assetID`, box (`bboxX/Y/W/H`, normalized, top-left origin), quality, `isManual`, `isIgnored`, `embeddingID` |
| `persons` / `person_face_membership` | People you named, and which faces belong to them |
| `face_constraints` | "Same person" and "not this person" decisions you made |
| `embeddings` / `embedding_vectors` | Model name and version, and AES-GCM encrypted vectors |
| `removal_queue`, `edit_projects`, `activity_log`, `settings` | Removal queue, edit recipes, local log and preferences |

The schema is versioned with GRDB migrations (`grdb_migrations`). New versions only add to the schema.
