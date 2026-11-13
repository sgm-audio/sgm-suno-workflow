# Suno AI Workflow Suite — Changelog

## 1.2.0 (2026-11-13) — audit release

Verified against the official REAPER API (`justinfrankel/reaper-sdk`), the
ReaTeam/ReaScripts conventions and the ReaPack source. Full details in
[`AUDIT_REPORT.md`](AUDIT_REPORT.md). Notable fixes:

### Blocking (scripts could not complete a run)
- **SGM_Suno ZIP Importer 1.1.2**: `reaper.GetTempPath()` is not a REAPER API function — importing always failed with "attempt to call a nil value". The temp folder now comes from `TEMP`/`TMPDIR`.
- **Suno_02_TempoMapper 1.0.1 / Suno_03_DynamicSplitter 1.0.1 / Suno_04_LoudnessMaster 1.0.1**: the peak-cache call used `MediaItemTake_GetPeaks`, which does not exist; the API function is `GetMediaItemTake_Peaks`. Every run aborted.
- All three also mis-read the peak buffer: the return value is bit-packed (count in the low 20 bits), the buffer is a maximums block followed by a minimums block (interleaved per channel), and `starttime` is **project** time, not 0.

### Correctness
- **Suno_03**: sensitivity was inverted — higher values produced *more* splits while the prompt and docs said the opposite. Now 0.1 = loose (more splits), 1.0 = strict.
- **Suno_04**: measures real samples through `GetAudioAccessorSamples` (true RMS and sample peak) instead of guessing RMS from window peaks; peak-cache path kept as a fallback.
- **Suno_02**: the "guard" tempo marker repeated the new BPM (a no-op); it now restores the tempo in force before the item.
- **Suno_01**: strips a Suno ID that sits *before* the stem suffix; creates one region per song span instead of one per stem track.
- **Suno_05**: the bus is created even when folder creation is disabled (it used to be silently skipped); folders are no longer created across other songs' tracks or over an existing folder hierarchy; a failed `CreateTrackSend` is detected.
- All prompt parsers: an empty field no longer shifts every following parameter.

### Security / robustness (ZIP importer)
- Every path passed to `unzip` / `ls` / `rm` is single-quoted for the shell; the temp folder name derived from the ZIP filename is sanitised. A ZIP named `$(cmd).zip` can no longer execute anything.
- `\uXXXX` escapes in `info.json` are decoded (including surrogate pairs); non-string values no longer return a later string from the file.
- `.m4a`, `.flac`, `.ogg`, `.opus`, `.aif(f)` are imported alongside `.mp3`/`.wav`.
- The temp folder is cleaned on every path, and an empty folder track is never left open.

### Packaging / tooling
- `index.xml`: package names now include the `.lua` extension (ReaPack installs a source under its package name, so extension-less names produced files REAPER cannot load). The bundle now declares every provided file as a `<source file=...>`, so `@provides` resolves.
- Removed the invalid `@provides [main] .` from the ZIP importer (it is not a metapackage).
- Deprecated `AddTempoTimeSigMarker` replaced with `SetTempoTimeSigMarker`.
- Added `tests/` (mock ReaScript API + 223 assertions), `tools/lua_lint.py` and expanded CI: syntax, lint, API-name verification against the official SDK list, and behaviour tests.


## 1.1.3 (2026-11-06)
- **Suno_01_MetadataOrganizer v1.0.2**: Fix stem detection when a Suno ID suffix is present (ID is now stripped before stem matching)
- **Suno_05_StemAligner v1.0.2**: Fix song-name extraction (Suno ID length validated on the ID, stem stripped after ID removal); folder/bus track indices computed from live track numbers (safe for interleaved groups); nil-check track creation
- **Bundle v1.1.2**: Fix `@provides` path for the ZIP importer (`Various/SGM_Suno ZIP Importer.lua`)

## 1.1.2 (2026-11-06)
- **Suno ZIP Importer v1.1.1**: Validate all ZIP member paths before extraction — rejects absolute paths, drive letters, and `..` segments (zip-slip / path-traversal guard); fails closed if the archive can't be listed
- **Suno ZIP Importer v1.1.1**: Nil-guard folder track and per-stem tracks so a failed `InsertTrackAtIndex` can no longer crash REAPER (undo block is always balanced)

## 1.1.1 (2026-06-03)
- **Bundle**: Updated `@provides` to list all 6 sub-scripts explicitly
- **Bundle**: Updated `@changelog` with full version history
- **Suno_01_MetadataOrganizer v1.0.1**: Fixed Suno ID regex detection (invalid `{8,32}` Lua pattern → `%w+` with length validation 8–32)
- **Suno_01_MetadataOrganizer v1.0.1**: Fixed stem label casing (removed erroneous `:upper()` call that broke `:gsub`)
- **Suno_05_StemAligner v1.0.1**: Fixed Suno ID stripping (same `{8,32}` pattern fix)
- **Repository**: ZIP importer renamed to `Various/SGM_Suno ZIP Importer.lua`

## 1.1.0 (2026-05-28)
- **Suno_ZIP_Importer v1.1.0**: Major update — replaced `os.execute` unzip with ReaImGui file dialog + progress window
- **Suno_ZIP_Importer v1.1.0**: Added lyric import as project markers (CC series)
- **Bundle**: Added SGM_SunoWorkflow_Bundle.lua metapackage

## 1.0.0 (2026-05-15)
- **Initial release** of all 6 scripts:
  - `Suno_ZIP_Importer.lua` — ZIP import with WAV extraction
  - `Suno_01_MetadataOrganizer.lua` — track renaming + color regions
  - `Suno_02_TempoMapper.lua` — BPM detection + guard marker
  - `Suno_03_DynamicSplitter.lua` — section-based splitting
  - `Suno_04_LoudnessMaster.lua` — -14 LUFS normalization
  - `Suno_05_StemAligner.lua` — stem grouping + alignment
