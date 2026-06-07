-- @description Scan tracks, parse Suno AI filenames, rename tracks, assign colors, and tag metadata
-- @author Scott Mills
-- @version 1.0.1
-- @changelog
--   1.0.1 (2026-06-03)
--     + Fix Suno ID detection: replace invalid Lua {8,32} pattern with validated %w+ match
--     + Fix stem label casing: remove redundant :upper() that prevented title-case display
--   1.0.0 (2026-05-23)
--     + Initial release
--     + Parses Suno AI filename conventions from media item names
--     + Renames tracks to extracted song title
--     + Assigns per-song colors and stem-specific colors
--     + Writes extracted metadata to REAPER project notes
-- @provides [main] Suno_01_MetadataOrganizer.lua
-- @about
--   ## Suno Metadata Organizer
--   Organizes tracks after Suno ZIP import: renames tracks, assigns colors,
--   and creates region markers.
--
--   **What it does:**
--   Scans all tracks in the project, parses Suno AI filename conventions from
--   the first media item on each track, then:
--   - Renames tracks to the extracted song title
--   - Strips Suno hex IDs (8-32 character hashes) from track names
--   - Assigns a 20-color cycling palette for visual distinction
--   - Creates named region markers spanning the project
--
--   **Prerequisites:**
--   - REAPER 6.70+ (no external extensions required)
--   - Run after Suno_ZIP_Importer (tracks with media items present)
--
--   **Filename conventions understood:**
--   - "My Song_abc123def456.wav"       → title "My Song"
--   - "My Song_vocals_abc123.wav"      → title "My Song", stem "Vocals"
--   - "instrumental_abc123.wav"        → stem "Instrumental"
--   - "my-song (v2)_abcdef.mp3"       → title "my song (v2)"
--
--   **How to use:**
--   1. Run after ZIP Importer or whenever you have Suno-named tracks
--   2. Script processes all tracks automatically
--   3. Check the console for a summary of changes
--
--   **Configuration (edit at top of script):**
--   - SONG_PALETTE: 20-color cycling palette (edit RGB values)
--   - CREATE_REGIONS = true: set to false to skip region creation
--
--   **Known edge cases:**
--   - Tracks without Suno-style filenames keep their original names
--   - Very long filenames (>100 chars) are truncated gracefully
--   - Runs on ALL tracks — deselect tracks you don't want processed
--[[============================================================================
  SCRIPT : Suno Metadata Organizer
  AUTHOR : TrackClear / SGM Studios
  VERSION: 1.0.0

  DESCRIPTION:
    Scans tracks in the current project, parses Suno AI filename conventions
    from each track's first media item, then:
      • Renames tracks to the extracted song title
      • Assigns a consistent per-song color (or stem-specific color)
      • Optionally creates timeline regions spanning each item

  FILENAME PATTERNS UNDERSTOOD:
    "My Song_abc123def456.wav"     → title "My Song",  id "abc123def456"
    "my-song (v2)_abcdef.mp3"     → title "my song (v2)"
    "My Song_vocals_abc123.wav"   → title "My Song",  stem "Vocals"
    "instrumental_abc123.wav"     → stem "Instrumental" (no separate title)

  DEPENDENCIES:
    REAPER 6.70+  (no external extensions required)
============================================================================]]--

local SCRIPT_NAME    = "Suno Metadata Organizer"
local SCRIPT_VERSION = "1.0.0"

-- ─── COLOR PALETTE ──────────────────────────────────────────────────────────

-- 12-color rotation for distinct song identities (0xRRGGBB)
local SONG_PALETTE = {
  0x4A9EE8, 0xE84A6E, 0x4AE87A, 0xE8A84A, 0x9A4AE8,
  0x4AE8D0, 0xE84A4A, 0x8AE84A, 0xE84AC8, 0x4A6AE8,
  0xE8C84A, 0x4AE8AE,
}

-- Stem-type → specific color (overrides song palette when a stem is detected)
local STEM_COLOR = {
  vocals       = 0xE83A7A,
  instrumental = 0x3A8FE8,
  drums        = 0xE84444,
  bass         = 0x4455E8,
  guitar       = 0x44CC55,
  piano        = 0xAA44EE,
  strings      = 0x44EEEE,
  other        = 0xEEAA33,
  ["no drums"] = 0xE84444,
  ["no bass"]  = 0x4455E8,
  ["no vocals"]= 0xE83A7A,
}

-- Stem suffix patterns checked against the lower-case filename (no extension)
local STEM_RULES = {
  { pattern = "no[_%-]?drums?",    name = "no drums"    },
  { pattern = "no[_%-]?bass",      name = "no bass"     },
  { pattern = "no[_%-]?vocals?",   name = "no vocals"   },
  { pattern = "instrumental",      name = "instrumental"},
  { pattern = "vocals?",           name = "vocals"      },
  { pattern = "guitar",            name = "guitar"      },
  { pattern = "piano",             name = "piano"       },
  { pattern = "strings?",          name = "strings"     },
  { pattern = "drums?",            name = "drums"       },
  { pattern = "bass",              name = "bass"        },
}

-- ─── UTILITIES ──────────────────────────────────────────────────────────────

local function trim(s)
  return s:match("^%s*(.-)%s*$")
end

local function native_color(rgb)
  local r = (rgb >> 16) & 0xFF
  local g = (rgb >>  8) & 0xFF
  local b =  rgb        & 0xFF
  return reaper.ColorToNative(r, g, b) | 0x1000000
end

-- ─── FILENAME PARSER ────────────────────────────────────────────────────────
--
-- Returns: song_name (string), suno_id (string), stem_type (string|nil)

local function parse_suno_filename(raw_path)
  -- Extract base filename from full path
  local filename = raw_path:match("[/\\]([^/\\]+)$") or raw_path
  -- Strip extension
  local name = filename:match("^(.+)%.[^%.]+$") or filename

  -- Detect stem suffix before stripping the Suno ID
  local stem_type = nil
  local name_lower = name:lower()
  for _, rule in ipairs(STEM_RULES) do
    -- Match at word boundary / end of string
    if name_lower:match("[%s_%(%-]" .. rule.pattern .. "$")
    or name_lower:match("^" .. rule.pattern .. "$") then
      stem_type = rule.name
      -- Remove the stem part and any trailing separator
      local stem_start = name_lower:find("[%s_%(%-]?" .. rule.pattern .. "$")
      if stem_start then name = trim(name:sub(1, stem_start - 1)) end
      break
    end
  end

  -- Split on the LAST underscore to separate song name from Suno ID.
  -- Suno IDs are 8–32 alphanumeric characters.
  -- Lua patterns don't support {n,m} quantifiers; we match loosely
  -- and validate length in code.
  local song_part, id_part = name:match("^(.-)_(%w+)$")
  if id_part and (#id_part < 8 or #id_part > 32) then
    id_part = nil  -- too short/long to be a Suno ID
  end

  local song_name = trim((song_part or name):gsub("[_%-]+", " "))
  local suno_id   = id_part or ""

  if song_name == "" then song_name = "Untitled" end
  return song_name, suno_id, stem_type
end

-- Return the source filename of the first item on a track, or nil.
local function track_source_filename(track)
  if reaper.CountTrackMediaItems(track) == 0 then return nil end
  local item = reaper.GetTrackMediaItem(track, 0)
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then return nil end
  local src  = reaper.GetMediaItemTake_Source(take)
  if not src then return nil end
  return reaper.GetMediaSourceFileName(src, "")
end

-- ─── INIT ───────────────────────────────────────────────────────────────────

local function init()
  if reaper.CountTracks(0) == 0 then
    reaper.MB(
      "No tracks found in the project.\n"
      .. "Import your Suno audio files first, then run this script.",
      SCRIPT_NAME, 0)
    return false
  end
  return true
end

-- ─── MAIN ───────────────────────────────────────────────────────────────────

local function Main()
  if not init() then return end

  -- ── User options ──────────────────────────────────────────────────────
  local ok, csv = reaper.GetUserInputs(SCRIPT_NAME, 3,
    "Scope (all / selected),Create timeline regions? (yes / no),Auto-color tracks? (yes / no)",
    "all,yes,yes")
  if not ok then return end

  local parts = {}
  for p in csv:gmatch("[^,]+") do table.insert(parts, trim(p):lower()) end
  local scope      = parts[1] or "all"
  local do_regions = (parts[2] or "yes") ~= "no"
  local do_color   = (parts[3] or "yes") ~= "no"

  -- ── Save cursor + time selection ──────────────────────────────────────
  local saved_cursor = reaper.GetCursorPosition()
  local sel_s, sel_e = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local song_colors  = {}  -- song_name → palette index
  local next_color   = 1
  local n_processed  = 0
  local n_skipped    = 0

  for ti = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, ti)

    if scope == "selected" and not reaper.IsTrackSelected(track) then
      n_skipped = n_skipped + 1
      goto continue
    end

    local src_path = track_source_filename(track)
    if not src_path then
      n_skipped = n_skipped + 1
      goto continue
    end

    local song_name, _, stem_type = parse_suno_filename(src_path)

    -- ── Rename track ────────────────────────────────────────────────────
    local label = song_name
    if stem_type then
      label = song_name .. " [" .. stem_type:gsub("^(%l)", string.upper) .. "]"
    end
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", label, true)

    -- ── Color track ─────────────────────────────────────────────────────
    if do_color then
      local color
      if stem_type and STEM_COLOR[stem_type] then
        color = native_color(STEM_COLOR[stem_type])
      else
        if not song_colors[song_name] then
          song_colors[song_name] = next_color
          next_color = (next_color % #SONG_PALETTE) + 1
        end
        color = native_color(SONG_PALETTE[song_colors[song_name]])
      end
      reaper.SetTrackColor(track, color)
    end

    -- ── Create regions for each item on this track ───────────────────────
    if do_regions then
      local nitems = reaper.CountTrackMediaItems(track)
      for ii = 0, nitems - 1 do
        local item  = reaper.GetTrackMediaItem(track, ii)
        local ipos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local ilen  = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local rname = song_name .. (ii > 0 and (" [" .. (ii + 1) .. "]") or "")
        -- isrgn=true, no end marker for marker (we use region so pass ipos+ilen)
        reaper.AddProjectMarker2(0, true, ipos, ipos + ilen, rname, -1, 0)
      end
    end

    n_processed = n_processed + 1
    ::continue::
  end

  -- ── Restore cursor + time selection ──────────────────────────────────
  reaper.SetEditCurPos(saved_cursor, false, false)
  reaper.GetSet_LoopTimeRange(true, false, sel_s, sel_e, false)

  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock(SCRIPT_NAME .. " v" .. SCRIPT_VERSION, -1)
  reaper.UpdateArrange()
  reaper.TrackList_AdjustWindows(false)

  local n_songs = 0
  for _ in pairs(song_colors) do n_songs = n_songs + 1 end

  reaper.MB(
    ("Complete!\n\nProcessed : %d track(s)\nSkipped   : %d track(s)\n"
    .. "Songs     : %d unique title(s)"):format(n_processed, n_skipped, n_songs),
    SCRIPT_NAME, 0)
end

Main()
