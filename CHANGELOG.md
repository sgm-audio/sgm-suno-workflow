# Suno AI Workflow Suite — Changelog

## 1.1.2 (2026-11-06)
- **Suno ZIP Importer v1.1.1**: Validate all ZIP member paths before extraction — rejects absolute paths, drive letters, and `..` segments (zip-slip / path-traversal guard); fails closed if the archive can't be listed
- **Suno ZIP Importer v1.1.1**: Nil-guard folder track and per-stem tracks so a failed `InsertTrackAtIndex` can no longer crash REAPER (undo block is always balanced)

## 1.1.1 (2026-06-03)
- **Bundle**: Updated `@provides` to list all 6 sub-scripts explicitly
- **Bundle**: Updated `@changelog` with full version history
- **Suno_01_MetadataOrganizer v1.0.1**: Fixed Suno ID regex detection (invalid `{8,32}` Lua pattern → `%w+` with length validation 8–32)
- **Suno_01_MetadataOrganizer v1.0.1**: Fixed stem label casing (removed erroneous `:upper()` call that broke `:gsub`)
- **Suno_05_StemAligner v1.0.1**: Fixed Suno ID stripping (same `{8,32}` pattern fix)
- **Repository**: Reorganized into package folders; files moved to `Suno-Workflow-Suite/`

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
