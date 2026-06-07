# Suno AI Workflow Suite — Installation Guide

## Option 1: Install via ReaPack (Recommended)

1. Open REAPER → **Extensions** → **ReaPack** → **Import repositories**
2. Copy and paste this URL:
   ```
   https://raw.githubusercontent.com/SGM-Studios/sgm-suno-workflow/main/index.xml
   ```
3. Click **Import** → **OK**
4. Go to **Extensions** → **ReaPack** → **Browse packages**
5. Search for **SGM SunoWorkflow Bundle** or **Suno**
6. Right-click → **Install**
7. Click **Apply** — all 6 scripts and the bundle metapackage are installed
8. Open **Actions** list (press `?`) and search for each script name to add toolbar buttons or keyboard shortcuts

## Option 2: Manual Installation

1. **Copy the scripts** to your REAPER user scripts folder:
   - Windows: `%APPDATA%\REAPER\Scripts\SGM Studios\Suno-Workflow-Suite\`
   - macOS: `~/Library/Application Support/REAPER/Scripts/SGM Studios/Suno-Workflow-Suite/`
   - Linux: `~/.config/REAPER/Scripts/SGM Studios/Suno-Workflow-Suite/`

   Copy ALL files from this folder:
   - `Suno_ZIP_Importer.lua`
   - `Suno_01_MetadataOrganizer.lua`
   - `Suno_02_TempoMapper.lua`
   - `Suno_03_DynamicSplitter.lua`
   - `Suno_04_LoudnessMaster.lua`
   - `Suno_05_StemAligner.lua`
   - `SGM_SunoWorkflow_Bundle.lua` (optional — metapackage for ReaPack only)

2. **Register the scripts** in REAPER:
   - Open **Actions** → **Show action list** (press `?`)
   - Click **New action** → **Load ReaScript**
   - Navigate to each `.lua` file and select it
   - Each script now appears in the Actions list

3. **Install dependencies**:
   - **ReaImGui** (required for ZIP Importer):
     - Extensions → ReaPack → Browse packages → Search "ReaImGui" → Install
     - Or download from: https://github.com/cfillion/reaimgui
   - **SWS Extension** (recommended):
     - Download from: https://www.sws-extension.org/
   - **7-Zip** (Windows, recommended for ZIP extraction):
     - Download from: https://www.7-zip.org/
     - Or ensure PowerShell's `Expand-Archive` is available (built into Windows 10+)

## Verifying Installation

1. Open REAPER
2. Press `?` to open the Actions list
3. Search for **SGM Suno** — you should see all 6 scripts
4. Run any script (requires a project with audio to do something useful)
5. Check the REAPER console (View → Console) for output

## Troubleshooting

| Symptom | Solution |
|---------|----------|
| Script not found in Actions | Check the file is in the correct folder, run **Actions → Re-scan** |
| ZIP Importer won't open | Install ReaImGui via ReaPack |
| "Error loading script" | Check for syntax errors with `luac -p filename.lua` |
| Colors not applying | Script uses `ColorToNative` with `\| 0x1000000` flag — this is correct for REAPER 6+ |
| Tempo detection wrong | Set `MANUAL_BPM = 0` to auto-detect, or set exact BPM value at top of script |
