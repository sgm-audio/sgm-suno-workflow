# Suno AI Workflow Suite for REAPER

[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![REAPER](https://img.shields.io/badge/REAPER-7.0%2B-blue)](https://www.reaper.fm/)
[![ReaPack](https://img.shields.io/badge/ReaPack-index-orange)](index.xml)

**Import, organize, and master Suno AI-generated audio inside REAPER — end to end.**

This six-script pipeline takes your raw Suno AI exports (ZIP files with stems) and turns them into a polished, organized, mix-ready REAPER project. Import → label → tempo-map → split → loudness-normalize → align stems.

---

## Pipeline

```
Suno ZIP Export
      │
      ▼
┌─────────────────────┐
│ Suno_ZIP_Importer   │  Import ZIP → tracks + markers + lyrics
└─────────┬───────────┘
          ▼
┌─────────────────────┐
│ Metadata Organizer  │  Rename tracks, assign colors, create regions
└─────────┬───────────┘
          ▼
┌─────────────────────┐
│ Tempo Mapper        │  Detect BPM, place tempo markers, guard marker
└─────────┬───────────┘
          ▼
┌─────────────────────┐
│ Dynamic Splitter    │  Split items at section boundaries
└─────────┬───────────┘
          ▼
┌─────────────────────┐
│ Loudness Master     │  Gain to -18 dBFS RMS (rough -14 LUFS)
└─────────┬───────────┘
          ▼
┌─────────────────────┐
│ Stem Aligner        │  Group + align stems by song name
└─────────────────────┘
```

---

## Scripts (Run in Order)

| # | Script | What It Does |
|---|--------|-------------|
| 1 | **Suno_ZIP_Importer** | Opens a ReaImGui file dialog to pick a Suno ZIP. Extracts the archive, imports WAV files onto new tracks, creates region markers from filenames, and imports lyrics as project markers. |
| 2 | **Suno_01_MetadataOrganizer** | Renames tracks from their file names, strips Suno IDs (8–32 character hex hashes), assigns a 20-color cycling palette, and creates named region markers from the track names. |
| 3 | **Suno_02_TempoMapper** | Detects the track BPM using an RMS-onset algorithm on the first item, sets the project tempo, and inserts a guard marker at the end of the arrangement. Supports manual override via the `MANUAL_BPM` constant. |
| 4 | **Suno_03_DynamicSplitter** | Splits items at detected transient boundaries. Adjustable sensitivity slider. Right-to-left split order prevents item drift. Names sections based on adjacent region markers. |
| 5 | **Suno_04_LoudnessMaster** | Gain-normalizes items. It isn't a LUFS meter: it estimates RMS from REAPER's 100 Hz peak cache, applies item gain to hit -18 dBFS RMS (I use that as a rough stand-in for -14 LUFS), and backs the gain off if the peak would go over -0.3 dBFS. That's a peak-cache sample peak, not true peak. Check the result on a real loudness meter. |
| 6 | **Suno_05_StemAligner** | Groups tracks by base song name (strips "-vocals", "-instrumental", etc.), creates folder/bus tracks, aligns group start times, and names folders. |
| — | **SGM_SunoWorkflow_Bundle** | ReaPack metapackage — installing this pulls all 6 scripts above. |

---

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| **REAPER** | 7.0+ | Scripts use modern API calls |
| **ReaImGui** | latest | Required only for Suno_ZIP_Importer (file dialog + progress window) |
| **SWS Extension** | 2.14+ | Recommended but not required |
| **7-Zip** (Windows) | any | Used by Suno_ZIP_Importer for ZIP extraction; falls back to PowerShell Expand-Archive |

Install ReaImGui via ReaPack: browse for "ReaImGui" or paste the ReaTeam index URL in Extensions → ReaPack → Import repositories.

---

## Quick Start

1. **Export your Suno song** as a ZIP file (stems + metadata).
2. **Run Suno_ZIP_Importer** — pick the ZIP, let it import.
3. **Run scripts 2–6 in order** — each builds on the previous.

Each script shows a console message when complete. If something goes wrong, check the REAPER console (View → Console) for error messages.

---

## Configuration Tips

- **Suno_ZIP_Importer**: Edit `IMPORT_LYRICS = true` at the top of the script to disable lyric import.
- **Suno_02_TempoMapper**: Set `MANUAL_BPM = 0` for auto-detect, or set `MANUAL_BPM = 128` to force a specific BPM.
- **Suno_03_DynamicSplitter**: Adjust sensitivity via the console prompt; lower values = more splits.
- **Suno_04_LoudnessMaster**: Edit `DEFAULT_TARGET = "-18"` (dBFS RMS) and `PEAK_CEILING = -0.3` (dBFS) at the top, or type new values in the prompt when it runs.
- **Suno_05_StemAligner**: Enable `DRY_RUN = true` to preview group assignments without making changes.

---

## License

MIT — see [`LICENSE`](LICENSE) and the `@license` header in each script. Free for personal and commercial use.

---

## Known limitations (ZIP importer)

`Suno_ZIP_Importer.lua` extracts archives via shell (`7z`, PowerShell `Expand-Archive`, or `unzip`). As of v1.1.1, every ZIP member path is validated **before** extraction — archives containing absolute paths, drive letters, or `..` segments are rejected (zip-slip protection). Remaining caveat: extraction still shells out, so only import ZIPs from sources you trust.

---

## Support

For issues, open a ticket on the ReaPack repository or contact **SGM Studios**.
