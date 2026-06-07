# Suno AI Workflow Suite — Test Cases

> **Instructions**: Run each test case manually in REAPER. Mark `[x]` for pass, `[ ]` for fail. Note the REAPER version and script versions tested.

**Tester**: \_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_
**Date**: \_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_
**REAPER Version**: \_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_\_

---

## Suno_ZIP_Importer

### TC-ZIP-01: Import a valid Suno ZIP
- **Prerequisites**: A valid Suno ZIP file with at least one WAV + metadata. ReaImGui installed.
- **Steps**:
  1. Create new empty REAPER project
  2. Run Suno_ZIP_Importer
  3. Select the Suno ZIP file in the file dialog
  4. Wait for extraction to complete
- **Expected Result**: All WAV files imported onto separate tracks. Region markers created from filenames. Lyrics markers created (if lyrics present).
- **Pass**: [ ] / [ ]

### TC-ZIP-02: Handle corrupt or invalid ZIP
- **Prerequisites**: A corrupted ZIP file (rename a .txt to .zip, or truncate a real ZIP).
- **Steps**:
  1. Run Suno_ZIP_Importer
  2. Select the corrupt ZIP
- **Expected Result**: Script shows an error message and does NOT crash REAPER. No orphan tracks created.
- **Pass**: [ ] / [ ]

### TC-ZIP-03: Run without ReaImGui
- **Prerequisites**: ReaImGui NOT installed.
- **Steps**:
  1. Run Suno_ZIP_Importer
- **Expected Result**: Script errors gracefully with a message about missing ReaImGui dependency (not a Lua error trace).
- **Pass**: [ ] / [ ]

### TC-ZIP-04: Import ZIP with lyrics
- **Prerequisites**: Suno ZIP that includes lyrics metadata.
- **Steps**:
  1. Run Suno_ZIP_Importer
  2. Select the ZIP
  3. After import, inspect project markers
- **Expected Result**: Lyrics text appears as project markers (View → Project markers).
- **Pass**: [ ] / [ ]

### TC-ZIP-05: Import ZIP without lyrics
- **Prerequisites**: Suno ZIP with no lyrics (or disable `IMPORT_LYRICS = false` at top of script).
- **Steps**:
  1. Run Suno_ZIP_Importer
  2. Select the no-lyrics ZIP
- **Expected Result**: WAV files import correctly. No lyric markers created. No errors.
- **Pass**: [ ] / [ ]

---

## Suno_01_MetadataOrganizer

### TC-MD-01: Rename tracks from filenames
- **Prerequisites**: Project with tracks named "track_1", "track_2", etc. (from ZIP import).
- **Steps**:
  1. Run Suno_01_MetadataOrganizer
- **Expected Result**: Track names updated to match file names. Suno ID hex strings (8–32 chars) stripped from names.
- **Pass**: [ ] / [ ]

### TC-MD-02: Color assignment
- **Prerequisites**: Same as TC-MD-01.
- **Steps**:
  1. Run Suno_01_MetadataOrganizer
  2. Inspect track colors
- **Expected Result**: Each track has a distinct color from the 20-color cycling palette. Colors visible in TCP and MCP.
- **Pass**: [ ] / [ ]

### TC-MD-03: Region creation
- **Prerequisites**: Same as TC-MD-01.
- **Steps**:
  1. Run Suno_01_MetadataOrganizer
  2. View Regions/Marker Manager
- **Expected Result**: Named region markers created for each track, spanning the full project.
- **Pass**: [ ] / [ ]

### TC-MD-04: Suno ID stripping from filenames
- **Prerequisites**: Tracks named like "MySong_a1b2c3d4e5f6g7h8_vocals.wav" (contains 16-char hex ID).
- **Steps**:
  1. Run Suno_01_MetadataOrganizer
- **Expected Result**: Track name becomes "MySong_vocals" — hex ID removed. IDs of lengths 8–32 chars are all handled.
- **Pass**: [ ] / [ ]

---

## Suno_02_TempoMapper

### TC-TM-01: BPM detection on known-tempo audio
- **Prerequisites**: An audio item with a clear, known tempo (e.g., a 128 BPM house track).
- **Steps**:
  1. Run Suno_02_TempoMapper
  2. Check project BPM after script completes
- **Expected Result**: Detected BPM within ±3 BPM of the known tempo.
- **Pass**: [ ] / [ ]

### TC-TM-02: Manual BPM override
- **Prerequisites**: Any project with audio. `MANUAL_BPM = 120` set at top of script.
- **Steps**:
  1. Run Suno_02_TempoMapper
- **Expected Result**: Project tempo set to exactly 120 BPM regardless of audio content.
- **Pass**: [ ] / [ ]

### TC-TM-03: Guard marker placement
- **Prerequisites**: Any project with at least one audio item.
- **Steps**:
  1. Run Suno_02_TempoMapper
  2. Check project markers
- **Expected Result**: A guard marker placed after the last item/extremity of the project.
- **Pass**: [ ] / [ ]

### TC-TM-04: Run on silent audio
- **Prerequisites**: Project with silent or extremely quiet audio items.
- **Steps**:
  1. Run Suno_02_TempoMapper
- **Expected Result**: Script completes without error. BPM may be detected as very slow (silent RMS → fallback). No crash.
- **Pass**: [ ] / [ ]

---

## Suno_03_DynamicSplitter

### TC-DS-01: Section detection on clear boundaries
- **Prerequisites**: An audio item with distinct section changes (verse → chorus → verse).
- **Steps**:
  1. Run Suno_03_DynamicSplitter
  2. Accept default sensitivity
- **Expected Result**: Item split at section boundaries. Regions/Markers show section names.
- **Pass**: [ ] / [ ]

### TC-DS-02: Sensitivity slider extremes
- **Prerequisites**: Same as TC-DS-01.
- **Steps**:
  1. Run Suno_03_DynamicSplitter with very low sensitivity
  2. Run again with very high sensitivity
- **Expected Result**: Low sensitivity → fewer splits. High sensitivity → more splits. No crash at either extreme.
- **Pass**: [ ] / [ ]

### TC-DS-03: Right-to-left split correctness
- **Prerequisites**: Item with multiple split points.
- **Steps**:
  1. Run Suno_03_DynamicSplitter
  2. After split, check that all items are contiguous with no gaps and no overlaps
- **Expected Result**: Total duration of split items = original item duration. No gaps between split items.
- **Pass**: [ ] / [ ]

### TC-DS-04: Run on very short item
- **Prerequisites**: A very short audio item (< 1 second).
- **Steps**:
  1. Run Suno_03_DynamicSplitter
- **Expected Result**: Script handles gracefully — either one split at midpoint, or no split with console message. No crash.
- **Pass**: [ ] / [ ]

---

## Suno_04_LoudnessMaster

### TC-LM-01: Normalization to -14 LUFS
- **Prerequisites**: An audio item with known loudness (e.g., a -20 LUFS file).
- **Steps**:
  1. Run Suno_04_LoudnessMaster
  2. Measure item loudness with a LUFS meter (e.g., Youlean Loudness Meter)
- **Expected Result**: Post-script integrated LUFS ≈ -14 ± 1 LUFS.
- **Pass**: [ ] / [ ]

### TC-LM-02: Peak ceiling enforcement
- **Prerequisites**: An audio item with peaks near 0 dBFS.
- **Steps**:
  1. Run Suno_04_LoudnessMaster
  2. Check item peaks
- **Expected Result**: Maximum peak ≤ -1.0 dBTP (or whatever PEAK_CEILING is set to).
- **Pass**: [ ] / [ ]

### TC-LM-03: Run on already-normalized item
- **Prerequisites**: An audio item already at ≈ -14 LUFS.
- **Steps**:
  1. Run Suno_04_LoudnessMaster
- **Expected Result**: Minimal gain change applied (< 0.5 dB difference). No distortion or clipping.
- **Pass**: [ ] / [ ]

### TC-LM-04: Run on silent item
- **Prerequisites**: A silent audio item.
- **Steps**:
  1. Run Suno_04_LoudnessMaster
- **Expected Result**: Script handles gracefully — gain may boost significantly (silent RMS → large gain), but no crash or NaN output.
- **Pass**: [ ] / [ ]

---

## Suno_05_StemAligner

### TC-SA-01: Grouping by song name
- **Prerequisites**: Multiple tracks with stems from 2+ different songs (e.g., "SongA_vocals", "SongA_guitar", "SongB_vocals", "SongB_drums").
- **Steps**:
  1. Run Suno_05_StemAligner
- **Expected Result**: Tracks grouped by base song name. All "SongA_*" tracks in one group, all "SongB_*" in another.
- **Pass**: [ ] / [ ]

### TC-SA-02: Alignment
- **Prerequisites**: Same as TC-SA-01, with stems that have different start offsets.
- **Steps**:
  1. Run Suno_05_StemAligner
  2. Inspect item start times within each group
- **Expected Result**: All items within a group start at the same time (aligned to first item start).
- **Pass**: [ ] / [ ]

### TC-SA-03: Folder/bus creation
- **Prerequisites**: Same as TC-SA-01.
- **Steps**:
  1. Run Suno_05_StemAligner
  2. Inspect track structure
- **Expected Result**: Each stem group has a parent folder track. Optional: bus track created with sends from all tracks in group.
- **Pass**: [ ] / [ ]

### TC-SA-04: Single-track group
- **Prerequisites**: A song with only one stem (e.g., "SongA_master.wav").
- **Steps**:
  1. Run Suno_05_StemAligner
- **Expected Result**: Single-stem group still creates a folder track for consistency. No alignment change needed. No errors.
- **Pass**: [ ] / [ ]

---

## Summary

| Test | Pass/Fail |
|------|-----------|
| TC-ZIP-01 | [ ] / [ ] |
| TC-ZIP-02 | [ ] / [ ] |
| TC-ZIP-03 | [ ] / [ ] |
| TC-ZIP-04 | [ ] / [ ] |
| TC-ZIP-05 | [ ] / [ ] |
| TC-MD-01 | [ ] / [ ] |
| TC-MD-02 | [ ] / [ ] |
| TC-MD-03 | [ ] / [ ] |
| TC-MD-04 | [ ] / [ ] |
| TC-TM-01 | [ ] / [ ] |
| TC-TM-02 | [ ] / [ ] |
| TC-TM-03 | [ ] / [ ] |
| TC-TM-04 | [ ] / [ ] |
| TC-DS-01 | [ ] / [ ] |
| TC-DS-02 | [ ] / [ ] |
| TC-DS-03 | [ ] / [ ] |
| TC-DS-04 | [ ] / [ ] |
| TC-LM-01 | [ ] / [ ] |
| TC-LM-02 | [ ] / [ ] |
| TC-LM-03 | [ ] / [ ] |
| TC-LM-04 | [ ] / [ ] |
| TC-SA-01 | [ ] / [ ] |
| TC-SA-02 | [ ] / [ ] |
| TC-SA-03 | [ ] / [ ] |
| TC-SA-04 | [ ] / [ ] |
| **Total Pass** | **\_\_/24** |
