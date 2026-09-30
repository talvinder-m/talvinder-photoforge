// Generated from docs/schema/0001_initial.sql — keep them identical.
// Embedded as source (not a bundle resource) so the packaged .app needs no
// SwiftPM resource bundle next to the executable.

enum Migrations {
    static let v0001_initial = """
-- PhotoForge AI — migration 0001 (initial schema)
-- Applied by GRDB DatabaseMigrator (see Sources/PFDatabase/Migrations.swift).
-- Conventions:
--   * ids are INTEGER PRIMARY KEY (rowid) unless a stable external key is needed.
--   * timestamps are REAL seconds since 1970 (UTC). Swift Date <-> Double.
--   * booleans are INTEGER 0/1 with CHECK constraints.
--   * enums are TEXT with CHECK constraints so bad values fail loudly.
--   * vectors are NEVER stored inline in hot tables; see `embeddings`.
--   * this database is the app's own. Apple's Photos.sqlite is never written.

PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------------------
-- Sources: the Photos System Library, an inspected .photoslibrary (read-only),
-- or a plain import folder chosen via security-scoped bookmark.
-- ---------------------------------------------------------------------------
CREATE TABLE source_libraries (
    id                  INTEGER PRIMARY KEY,
    kind                TEXT NOT NULL CHECK (kind IN ('photokit_system','photoslibrary_readonly','import_folder')),
    displayName         TEXT NOT NULL,
    bookmarkData        BLOB,                 -- security-scoped bookmark (folder / package)
    photoKitChangeToken BLOB,                 -- archived PHPersistentChangeToken for incremental sync
    lastFullScanAt      REAL,
    lastIncrementalAt   REAL,
    createdAt           REAL NOT NULL
);

-- ---------------------------------------------------------------------------
-- Assets
-- ---------------------------------------------------------------------------
CREATE TABLE assets (
    id                       INTEGER PRIMARY KEY,
    photoKitLocalIdentifier  TEXT,             -- NULL for import-folder assets
    sourceLibraryID          INTEGER NOT NULL REFERENCES source_libraries(id) ON DELETE CASCADE,
    originalFilename         TEXT,
    mediaType                TEXT NOT NULL CHECK (mediaType IN ('image','video','audio','unknown')),
    mediaSubtypeMask         INTEGER NOT NULL DEFAULT 0, -- PHAssetMediaSubtype raw bits (live, HDR, screenshot, burst…)
    uti                      TEXT,             -- e.g. public.heic, com.adobe.raw-image
    creationDate             REAL,
    modificationDate         REAL,
    pixelWidth               INTEGER,
    pixelHeight              INTEGER,
    duration                 REAL,
    fileSize                 INTEGER,
    favorite                 INTEGER NOT NULL DEFAULT 0 CHECK (favorite IN (0,1)),
    hidden                   INTEGER NOT NULL DEFAULT 0 CHECK (hidden IN (0,1)),
    burstIdentifier          TEXT,
    localAvailabilityState   TEXT NOT NULL DEFAULT 'unknown'
                             CHECK (localAvailabilityState IN ('local','cloud_only','downloading','unavailable','unknown')),
    fileHash                 BLOB,             -- SHA-256 of original resource (32 bytes) when accessible
    perceptualHash           INTEGER,          -- 64-bit pHash (signed int64 storage of UInt64 bits)
    differenceHash           INTEGER,          -- 64-bit dHash
    imageEmbeddingID         INTEGER REFERENCES embeddings(id) ON DELETE SET NULL,
    qualityScore             REAL,             -- 0…1 composite technical quality
    sharpnessScore           REAL,
    exposureScore            REAL,
    noiseScore               REAL,
    duplicateStatus          TEXT NOT NULL DEFAULT 'unscanned'
                             CHECK (duplicateStatus IN ('unscanned','unique','exact_dup','near_dup','similar','excluded')),
    analysisStage            INTEGER NOT NULL DEFAULT 0, -- bitmask of completed pipeline stages (see IndexStage)
    isDeletedInSource        INTEGER NOT NULL DEFAULT 0 CHECK (isDeletedInSource IN (0,1)),
    indexedAt                REAL,
    updatedAt                REAL NOT NULL,
    UNIQUE (sourceLibraryID, photoKitLocalIdentifier)
);
CREATE INDEX idx_assets_creation      ON assets(creationDate);
CREATE INDEX idx_assets_filehash      ON assets(fileHash) WHERE fileHash IS NOT NULL;
CREATE INDEX idx_assets_phash         ON assets(perceptualHash) WHERE perceptualHash IS NOT NULL;
CREATE INDEX idx_assets_burst         ON assets(burstIdentifier) WHERE burstIdentifier IS NOT NULL;
CREATE INDEX idx_assets_stage         ON assets(analysisStage);
CREATE INDEX idx_assets_dupstatus     ON assets(duplicateStatus);
CREATE INDEX idx_assets_plid          ON assets(photoKitLocalIdentifier);

CREATE TABLE asset_metadata (
    assetID            INTEGER PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
    cameraMake         TEXT,
    cameraModel        TEXT,
    lensModel          TEXT,
    aperture           REAL,
    focalLength        REAL,
    iso                INTEGER,
    shutterSpeed       REAL,
    latitudeEncrypted  BLOB,   -- AES-GCM sealed box; key in Keychain. NULL if location indexing disabled.
    longitudeEncrypted BLOB,
    keywordData        TEXT,   -- JSON array
    hasOCRText         INTEGER NOT NULL DEFAULT 0 CHECK (hasOCRText IN (0,1))
);

-- OCR text is full-text searchable. rowid == assets.id (FTS tables can't hold
-- foreign keys, so AssetStore deletes the row explicitly when an asset goes).
CREATE VIRTUAL TABLE ocr_text USING fts5(text, tokenize = 'unicode61 remove_diacritics 2');

CREATE TABLE tags (
    assetID    INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    label      TEXT NOT NULL,           -- scene/object label from Vision classification
    confidence REAL NOT NULL,
    source     TEXT NOT NULL,           -- model name
    PRIMARY KEY (assetID, label, source)
);
CREATE INDEX idx_tags_label ON tags(label);

-- ---------------------------------------------------------------------------
-- Embeddings: metadata here, vectors in `embedding_vectors` (sealed BLOBs)
-- and in the on-disk HNSW index file referenced by vectorIndexName/slot.
-- ---------------------------------------------------------------------------
CREATE TABLE embeddings (
    id               INTEGER PRIMARY KEY,
    entityType       TEXT NOT NULL CHECK (entityType IN ('asset','face')),
    entityID         INTEGER NOT NULL,
    modelName        TEXT NOT NULL,
    modelVersion     TEXT NOT NULL,
    dimension        INTEGER NOT NULL,
    vectorIndexName  TEXT NOT NULL,       -- e.g. 'faces-arcface-r100-v1'
    vectorIndexSlot  INTEGER,             -- label inside the HNSW index
    encrypted        INTEGER NOT NULL DEFAULT 1 CHECK (encrypted IN (0,1)),
    createdAt        REAL NOT NULL,
    UNIQUE (entityType, entityID, modelName, modelVersion)
);
CREATE INDEX idx_embeddings_index ON embeddings(vectorIndexName, vectorIndexSlot);

CREATE TABLE embedding_vectors (
    embeddingID INTEGER PRIMARY KEY REFERENCES embeddings(id) ON DELETE CASCADE,
    vector      BLOB NOT NULL            -- Float32 little-endian, sealed with AES-GCM when encrypted = 1
);

-- ---------------------------------------------------------------------------
-- Faces and people
-- ---------------------------------------------------------------------------
CREATE TABLE faces (
    id                 INTEGER PRIMARY KEY,
    assetID            INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    bboxX REAL NOT NULL, bboxY REAL NOT NULL, bboxW REAL NOT NULL, bboxH REAL NOT NULL, -- normalized, top-left origin, oriented image
    landmarks          BLOB,             -- packed Float32 pairs (normalized)
    embeddingID        INTEGER REFERENCES embeddings(id) ON DELETE SET NULL,
    faceQualityScore   REAL,             -- VNDetectFaceCaptureQualityRequest, 0…1
    blurScore          REAL,
    occlusionScore     REAL,
    yaw REAL, pitch REAL, roll REAL,     -- radians
    faceCropPath       TEXT,             -- relative path inside protected container; NULL if crops disabled
    isIgnored          INTEGER NOT NULL DEFAULT 0 CHECK (isIgnored IN (0,1)),
    createdAt          REAL NOT NULL
);
CREATE INDEX idx_faces_asset ON faces(assetID);

CREATE TABLE persons (
    id               INTEGER PRIMARY KEY,
    displayName      TEXT,               -- NULL => shown as "Possible Person"
    coverFaceID      INTEGER REFERENCES faces(id) ON DELETE SET NULL,
    confidenceState  TEXT NOT NULL DEFAULT 'needs_review'
                     CHECK (confidenceState IN ('confirmed','likely','needs_review','low_confidence')),
    isHidden         INTEGER NOT NULL DEFAULT 0 CHECK (isHidden IN (0,1)),
    createdAt        REAL NOT NULL,
    updatedAt        REAL NOT NULL
);

CREATE TABLE person_face_membership (
    personID          INTEGER NOT NULL REFERENCES persons(id) ON DELETE CASCADE,
    faceID            INTEGER NOT NULL REFERENCES faces(id) ON DELETE CASCADE,
    clusterSimilarity REAL,              -- cosine sim to person centroid at assignment time
    userConfirmed     INTEGER NOT NULL DEFAULT 0 CHECK (userConfirmed IN (0,1)),
    isReference       INTEGER NOT NULL DEFAULT 0 CHECK (isReference IN (0,1)),
    addedAt           REAL NOT NULL,
    PRIMARY KEY (faceID)                 -- a face belongs to at most one person
);
CREATE INDEX idx_pfm_person ON person_face_membership(personID);

-- Pairwise clustering constraints produced by user feedback.
-- Stored with faceA < faceB so each pair appears once.
CREATE TABLE face_constraints (
    faceA      INTEGER NOT NULL REFERENCES faces(id) ON DELETE CASCADE,
    faceB      INTEGER NOT NULL REFERENCES faces(id) ON DELETE CASCADE,
    kind       TEXT NOT NULL CHECK (kind IN ('must_link','cannot_link')),
    createdAt  REAL NOT NULL,
    PRIMARY KEY (faceA, faceB),
    CHECK (faceA < faceB)
);
-- Person-level "This is not [Person]" is expanded to face-level cannot-links
-- against that person's confirmed/reference faces at write time.

-- ---------------------------------------------------------------------------
-- Duplicates
-- ---------------------------------------------------------------------------
CREATE TABLE duplicate_groups (
    id                  INTEGER PRIMARY KEY,
    groupType           TEXT NOT NULL CHECK (groupType IN ('exact','near','burst','similar')),
    similarityScore     REAL NOT NULL,
    recommendedAssetID  INTEGER REFERENCES assets(id) ON DELETE SET NULL,
    recommendationWhy   TEXT,            -- human-readable explanation
    reviewState         TEXT NOT NULL DEFAULT 'pending'
                        CHECK (reviewState IN ('pending','reviewed','dismissed')),
    createdAt           REAL NOT NULL,
    updatedAt           REAL NOT NULL
);
CREATE INDEX idx_dupgroups_type_state ON duplicate_groups(groupType, reviewState);

CREATE TABLE duplicate_group_members (
    duplicateGroupID INTEGER NOT NULL REFERENCES duplicate_groups(id) ON DELETE CASCADE,
    assetID          INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    similarityScore  REAL NOT NULL,
    bestShotScore    REAL,
    rank             INTEGER NOT NULL,
    isRecommended    INTEGER NOT NULL DEFAULT 0 CHECK (isRecommended IN (0,1)),
    decision         TEXT NOT NULL DEFAULT 'undecided'
                     CHECK (decision IN ('undecided','keep','review_queue','delete_confirmed')),
    PRIMARY KEY (duplicateGroupID, assetID)
);
CREATE INDEX idx_dgm_asset ON duplicate_group_members(assetID);

-- "Mark as not similar" / "Exclude from future scans"
CREATE TABLE similarity_exclusions (
    assetA    INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
    assetB    INTEGER,                    -- NULL => exclude assetA from all future scans
    createdAt REAL NOT NULL,
    CHECK (assetB IS NULL OR assetA < assetB)
);
CREATE UNIQUE INDEX idx_simex_pair ON similarity_exclusions(assetA, IFNULL(assetB, -1));

-- ---------------------------------------------------------------------------
-- Editing & provenance
-- ---------------------------------------------------------------------------
CREATE TABLE edit_projects (
    id                   INTEGER PRIMARY KEY,
    sourceAssetID        INTEGER NOT NULL REFERENCES assets(id) ON DELETE RESTRICT,
    projectName          TEXT NOT NULL,
    editStackJSON        TEXT NOT NULL,   -- versioned EditStack (see PFEditing)
    editStackVersion     INTEGER NOT NULL,
    containsGenerative   INTEGER NOT NULL DEFAULT 0 CHECK (containsGenerative IN (0,1)),
    outputAssetID        TEXT,            -- PhotoKit localIdentifier of derivative, if exported to Photos
    outputPath           TEXT,
    aiModelMetadataJSON  TEXT,            -- models, versions, seeds, prompts, masks refs
    sourceChecksum       BLOB,            -- SHA-256 of source at time of access
    sourceAccessedAt     REAL NOT NULL,
    createdAt            REAL NOT NULL,
    updatedAt            REAL NOT NULL
);
CREATE INDEX idx_edit_source ON edit_projects(sourceAssetID);

-- ---------------------------------------------------------------------------
-- Jobs, decisions, audit
-- ---------------------------------------------------------------------------
CREATE TABLE jobs (
    id            INTEGER PRIMARY KEY,
    jobType       TEXT NOT NULL,
    payloadJSON   TEXT,
    status        TEXT NOT NULL DEFAULT 'queued'
                  CHECK (status IN ('queued','running','paused','succeeded','failed','cancelled')),
    progress      REAL NOT NULL DEFAULT 0,
    progressText  TEXT,
    priority      INTEGER NOT NULL DEFAULT 1,  -- 0 background, 1 utility, 2 userInitiated
    retryCount    INTEGER NOT NULL DEFAULT 0,
    errorMessage  TEXT,
    createdAt     REAL NOT NULL,
    startedAt     REAL,
    completedAt   REAL
);
CREATE INDEX idx_jobs_status_priority ON jobs(status, priority DESC, createdAt);

CREATE TABLE user_decisions (
    id               INTEGER PRIMARY KEY,
    decisionType     TEXT NOT NULL,   -- merge, split, not_person, keep_best, delete_confirmed, …
    subjectType      TEXT NOT NULL,   -- face, person, asset, duplicate_group
    subjectID        INTEGER NOT NULL,
    relatedSubjectID INTEGER,
    detailJSON       TEXT,
    createdAt        REAL NOT NULL
);
CREATE INDEX idx_decisions_subject ON user_decisions(subjectType, subjectID);

-- Optional, user-visible, user-deletable. Never contains pixels, embeddings or GPS.
CREATE TABLE activity_log (
    id         INTEGER PRIMARY KEY,
    category   TEXT NOT NULL CHECK (category IN ('scan','model','edit','export','delete','privacy','safety')),
    message    TEXT NOT NULL,
    execution  TEXT CHECK (execution IN ('local','cloud')),
    modelName  TEXT,
    assetCount INTEGER,
    createdAt  REAL NOT NULL
);
CREATE INDEX idx_activity_time ON activity_log(createdAt);

CREATE TABLE settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
INSERT INTO settings(key, value) VALUES
    ('faceAnalysisEnabled',   'true'),
    ('storeFaceCrops',        'true'),
    ('semanticIndexEnabled',  'true'),
    ('locationIndexEnabled',  'false'),
    ('activityLogEnabled',    'true'),
    ('cloudProvidersEnabled', 'false'),
    ('adultWorkflowEnabled',  'false');
"""

    /// Raw quality metrics shown in the comparison view, and face pixel size used by
    /// the clusterer's small-face penalty.
    static let v0002_metrics = """
    ALTER TABLE assets ADD COLUMN laplacianVariance REAL;
    ALTER TABLE assets ADD COLUMN noiseSigma REAL;
    ALTER TABLE assets ADD COLUMN meanLuma REAL;
    ALTER TABLE assets ADD COLUMN clippedFraction REAL;
    ALTER TABLE faces ADD COLUMN pixelSize REAL;
    """

    /// Photos the user marked for removal wait here until they confirm deletion.
    static let v0003_removal_queue = """
    CREATE TABLE removal_queue (
        assetID  INTEGER PRIMARY KEY REFERENCES assets(id) ON DELETE CASCADE,
        reason   TEXT NOT NULL,
        groupID  TEXT,
        addedAt  REAL NOT NULL
    );
    """

    /// Multiple libraries + iCloud separation.
    static let v0004_libraries = """
    ALTER TABLE assets ADD COLUMN assetSource TEXT NOT NULL DEFAULT 'library';
    ALTER TABLE assets ADD COLUMN filePath TEXT;
    ALTER TABLE source_libraries ADD COLUMN path TEXT;
    ALTER TABLE source_libraries ADD COLUMN lastOpenedAt REAL;
    ALTER TABLE persons ADD COLUMN sourceLibraryID INTEGER REFERENCES source_libraries(id) ON DELETE CASCADE;
    UPDATE persons SET sourceLibraryID = (SELECT id FROM source_libraries WHERE kind = 'photokit_system' LIMIT 1);
    CREATE INDEX idx_assets_source ON assets(sourceLibraryID, isDeletedInSource, mediaType);
    """

    /// Photo categories (documents, receipts, screenshots, WhatsApp, …). Automatic decisions and
    /// user overrides are separate rows so re-analysis never undoes a user's correction.
    static let v0005_categories = """
    CREATE TABLE asset_categories (
        assetID    INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
        category   TEXT NOT NULL,
        confidence REAL NOT NULL,
        reason     TEXT,
        source     TEXT NOT NULL CHECK (source IN ('auto','user')),
        PRIMARY KEY (assetID, category, source)
    );
    CREATE INDEX idx_asset_categories ON asset_categories(category, source);
    """

    /// Names (titles) for any photo, PhotoForge's own albums/folders for any library,
    /// and faces the user marked by hand.
    static let v0006_names_albums = """
    ALTER TABLE assets ADD COLUMN title TEXT;
    CREATE INDEX idx_assets_title ON assets(title);
    ALTER TABLE faces ADD COLUMN isManual INTEGER NOT NULL DEFAULT 0;
    CREATE TABLE pf_albums (
        id              INTEGER PRIMARY KEY,
        sourceLibraryID INTEGER REFERENCES source_libraries(id) ON DELETE CASCADE,
        parentID        INTEGER REFERENCES pf_albums(id) ON DELETE CASCADE,
        title           TEXT NOT NULL,
        isFolder        INTEGER NOT NULL DEFAULT 0 CHECK (isFolder IN (0,1)),
        createdAt       REAL NOT NULL
    );
    CREATE TABLE pf_album_members (
        albumID  INTEGER NOT NULL REFERENCES pf_albums(id) ON DELETE CASCADE,
        assetID  INTEGER NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
        addedAt  REAL NOT NULL,
        PRIMARY KEY (albumID, assetID)
    );
    CREATE INDEX idx_album_members_asset ON pf_album_members(assetID);
    """

    /// Smart albums (a rule instead of a member list) and a faster lookup for user tags.
    static let v0007_smart_albums_tags = """
    ALTER TABLE pf_albums ADD COLUMN rule TEXT;
    CREATE INDEX idx_tags_source_label ON tags(source, label);
    """
}
