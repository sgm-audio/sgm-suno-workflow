-- @description Organise third-party stem separations (UVR5, Demucs, Fadr) into a mix-ready layout
-- @author Scott Mills
-- @version 1.0.3
-- @changelog
--   1.0.3 (2026-11-13)
--     + Bus is created even when folder creation is disabled (it used to be
--       silently skipped because it was nested inside the folder branch)
--     + Never wrap other songs' tracks: folder creation is skipped (with a
--       console warning) when a group's tracks are not adjacent
--     + Never corrupt an existing folder hierarchy: groups whose tracks already
--       have I_FOLDERDEPTH set are left alone
--     + Guard against a failed CreateTrackSend (index -1)
--     + Remove the unused parameter in extract_song_name
--   1.0.2 (2026-11-06)
--     + Fix song-name extraction: validate Suno ID length (not song part), strip stem after ID removal
--     + Folder/bus indices now computed from live track numbers (safe for interleaved groups)
--     + Nil-check track creation in insert_named_track
--   1.0.1 (2026-06-03)
--     + Fix Suno ID stripping: replace invalid Lua {8,32} pattern with validated %w+ match
--   1.0.0 (2026-05-23)
--     + Initial release
--     + Detects stem-type suffixes in source filenames
--     + Assigns stem colors and bus routing
--     + Creates folder structure and FX chain stubs per stem type
-- @provides [main] Suno_05_StemAligner.lua
-- @about
--   ## Suno Stem Aligner
--   Groups and aligns stem tracks by song name, creates folder/bus structure.
--
--   **What it does:**
--   Scans all tracks in the project, detects stem-type suffixes in source
--   filenames (vocals, drums, bass, guitar, instrumental, etc.), groups stems
--   that share the same base song name into "sets", aligns all items in a set
--   to the same start time, and creates folder/bus tracks for each group.
--
--   **The pipeline:**
--   1. DETECT: Scans for stem-type suffixes in source filenames
--   2. GROUP: Clusters stems sharing the same base song name
--   3. ALIGN: Moves items to align at the earliest item start in the group
--   4. FOLDER: Creates parent folder track above each group
--   5. BUS: Optionally creates a stereo summing bus with post-fader sends
--   6. COLOR + NAME: Applies consistent stem-type colors and naming
--
--   **Prerequisites:**
--   - REAPER 6.70+ (no external extensions required)
--   - Run after Suno_04_LoudnessMaster
--   - Tracks with Suno-stem naming convention (e.g., "SongA_vocals", "SongA_drums")
--
--   **How to use:**
--   1. Run the script after loudness normalization
--   2. All stems are grouped and aligned automatically
--   3. Check the track list for new folder/bus tracks
--
--   **Configuration:**
--   - Options are prompted when the script runs (align / folder / bus yes-no)
--   - STEM_RULES at the top of the script: edit the recognized stem types
--
--   **Limitations:**
--   - REAPER has no direct "move track to index N" API — inserts new folder/bus
--     tracks adjacent to existing stem tracks
--   - Groups with a single stem are skipped (nothing to align)
--   - Stem detection relies on filename suffixes (configurable via STEM_RULES)
--[[============================================================================
  SCRIPT : Suno Stem Aligner
  AUTHOR : TrackClear / SGM Studios
  VERSION: 1.0.2

  DESCRIPTION:
    Organises third-party stem separations (from UVR5, Demucs, Fadr, etc.)
    derived from Suno tracks into a fully configured, mix-ready layout:

      1. DETECT: Scan all tracks for stem-type suffixes in their source filenames
         (vocals, drums, bass, guitar, instrumental, …).

      2. GROUP: Cluster stems that share the same base song name into "sets".

      3. ALIGN: Move every item in a stem set so it starts at the same project
         position as the earliest item in the group (the reference stem).
         All items within a group become time-aligned for immediate muxing.

      4. FOLDER: Insert a parent folder track above each group and assign all
         group tracks as its children.  Folder depth flags are set correctly
         so REAPER recognises the hierarchy.

      5. BUS: Optionally create a stereo summing bus track at the end of each
         folder.  Each stem track receives a post-fader send to its bus,
         providing an immediate mix-buss for the song.

      6. COLOR + NAME: Apply consistent stem-type colours and rename tracks
         using the "[Suno] Title (Stem)" convention.

  NOTE ON TRACK REORDERING:
    REAPER provides no direct "move track to index N" API.  This script inserts
    NEW folder and bus tracks adjacent to existing stem tracks using
    reaper.InsertTrackAtIndex, then sets I_FOLDERDEPTH flags.  Existing tracks
    are NOT physically reordered — they are placed inside the folder via depth
    flags on their immediate neighbours.

  DEPENDENCIES:
    REAPER 6.70+  (no external extensions required)
============================================================================]]--

local SCRIPT_NAME    = "Suno Stem Aligner"
local SCRIPT_VERSION = "1.0.3"

-- ─── STEM CLASSIFICATION ─────────────────────────────────────────────────────

-- Ordered from most specific to least specific.
-- `pattern`: matched against the lower-case source filename (no extension).
local STEM_RULES = {
  { pattern = "no[_%-]?drums?",    label = "No Drums",     color = 0xE84444 },
  { pattern = "no[_%-]?bass",      label = "No Bass",      color = 0x4455E8 },
  { pattern = "no[_%-]?vocals?",   label = "No Vocals",    color = 0xE83A7A },
  { pattern = "instrumental",      label = "Instrumental", color = 0x3A8FE8 },
  { pattern = "vocals?",           label = "Vocals",       color = 0xE83A7A },
  { pattern = "drums?",            label = "Drums",        color = 0xE84444 },
  { pattern = "bass",              label = "Bass",         color = 0x4455E8 },
  { pattern = "guitar",            label = "Guitar",       color = 0x44CC55 },
  { pattern = "piano",             label = "Piano",        color = 0xAA44EE },
  { pattern = "strings?",          label = "Strings",      color = 0x44EEEE },
  { pattern = "other",             label = "Other",        color = 0xEEAA33 },
}

local FOLDER_COLOR = 0x555566
local BUS_COLOR    = 0x888866

-- ─── UTILITIES ───────────────────────────────────────────────────────────────

local function trim(s) return s:match("^%s*(.-)%s*$") end

local function native_color(rgb)
  local r = (rgb >> 16) & 0xFF
  local g = (rgb >>  8) & 0xFF
  local b =  rgb        & 0xFF
  return reaper.ColorToNative(r, g, b) | 0x1000000
end

-- Insert a new named track at index `idx` and return it (nil on failure).
local function insert_named_track(idx, name, color_rgb)
  reaper.InsertTrackAtIndex(idx, true)
  local track = reaper.GetTrack(0, idx)
  if not track then return nil end
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", name, true)
  if color_rgb then reaper.SetTrackColor(track, native_color(color_rgb)) end
  return track
end

-- Return the source filename (base only) for the first item on a track.
local function source_basename(track)
  if reaper.CountTrackMediaItems(track) == 0 then return nil end
  local item = reaper.GetTrackMediaItem(track, 0)
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then return nil end
  local src  = reaper.GetMediaItemTake_Source(take)
  if not src then return nil end
  local full = reaper.GetMediaSourceFileName(src, "")
  local base = full:match("[/\\]([^/\\]+)$") or full
  -- Strip extension
  return base:match("^(.+)%.[^%.]+$") or base
end

-- Classify a filename (no-extension lower-case) into a stem label + color.
-- Returns nil if no stem pattern matches.
local function classify_stem(fname_lower)
  for _, rule in ipairs(STEM_RULES) do
    if fname_lower:match(rule.pattern) then
      return rule.label, rule.color
    end
  end
  return nil, nil
end

-- Extract the "song name" from a stem filename by stripping known stem suffixes
-- and the trailing Suno ID (alphanumeric, 8–32 chars after the last underscore).
local function extract_song_name(raw_fname)
  local name = raw_fname  -- preserve original case for display

  -- Strip Suno ID FIRST (last _XXXXXXXX segment).
  -- Lua patterns don't support {n,m}; validate the ID length in code.
  local song_part, id_part = name:match("^(.-)_(%w+)$")
  if id_part and #id_part >= 8 and #id_part <= 32 then
    name = song_part
  end

  -- Strip stem suffix at the end of the remaining name
  for _, rule in ipairs(STEM_RULES) do
    local s = name:lower():find("[%s_%(%-]?" .. rule.pattern .. "$")
    if s then name = trim(name:sub(1, s - 1)) end
  end

  name = trim(name:gsub("[_%-]+", " "))

  return (name ~= "" and name or "Untitled")
end

-- ─── GROUPING ────────────────────────────────────────────────────────────────

-- Scan all tracks and build a grouped structure.
-- Returns: groups (table of song_name → { tracks = [], ref_pos = number })
local function build_groups()
  local groups    = {}   -- ordered by first-seen song name
  local group_map = {}   -- song_name_lower → group entry

  for ti = 0, reaper.CountTracks(0) - 1 do
    local track    = reaper.GetTrack(0, ti)
    local basename = source_basename(track)
    if not basename then goto next_track end

    local fname_lower = basename:lower()
    local stem_label, stem_color = classify_stem(fname_lower)
    if not stem_label then goto next_track end  -- skip non-stem tracks

    local song_name = extract_song_name(basename)
    local key       = song_name:lower()

    if not group_map[key] then
      local g = { song_name = song_name, tracks = {}, ref_pos = math.huge }
      group_map[key] = g
      table.insert(groups, g)
    end

    -- Find the earliest item start on this track (= reference time candidate)
    local track_ref = math.huge
    for ii = 0, reaper.CountTrackMediaItems(track) - 1 do
      local it  = reaper.GetTrackMediaItem(track, ii)
      local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      if pos < track_ref then track_ref = pos end
    end

    local g = group_map[key]
    table.insert(g.tracks, {
      track      = track,
      stem_label = stem_label,
      stem_color = stem_color,
      track_idx  = ti,
      ref_pos    = track_ref,
    })
    if track_ref < g.ref_pos then g.ref_pos = track_ref end

    ::next_track::
  end

  -- Filter out single-track "groups" (nothing to align)
  local multi = {}
  for _, g in ipairs(groups) do
    if #g.tracks >= 2 then table.insert(multi, g) end
  end
  return multi
end

-- ─── ALIGNMENT ───────────────────────────────────────────────────────────────

-- Shift all items on a track by `delta` seconds (preserving relative offsets).
local function shift_track_items(track, delta)
  if math.abs(delta) < 0.0001 then return end
  for ii = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item    = reaper.GetTrackMediaItem(track, ii)
    local cur_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    reaper.SetMediaItemInfo_Value(item, "D_POSITION", cur_pos + delta)
  end
end

-- ─── FOLDER + BUS CREATION ───────────────────────────────────────────────────

-- Create a post-fader send from src_track to dest_track.
-- Returns true on success (CreateTrackSend returns -1 on failure).
local function create_post_fader_send(src_track, dest_track)
  local idx = reaper.CreateTrackSend(src_track, dest_track)
  if not idx or idx < 0 then return false end
  reaper.SetTrackSendInfo_Value(src_track, 0, idx, "I_SENDMODE", 0)  -- 0 = post-fader
  return true
end

-- ─── MAIN ────────────────────────────────────────────────────────────────────

local function init()
  if reaper.CountTracks(0) == 0 then
    reaper.MB("No tracks in project.", SCRIPT_NAME, 0)
    return false
  end
  return true
end

local function Main()
  if not init() then return end

  -- ── User options ──────────────────────────────────────────────────────
  local ok, csv = reaper.GetUserInputs(SCRIPT_NAME, 3,
    "Align item start times within each group? (yes/no),"
    .. "Create folder tracks? (yes/no),"
    .. "Create summing bus per group? (yes/no):",
    "yes,yes,yes")
  if not ok then return end

  local parts = {}
  for p in csv:gmatch("[^,]+") do table.insert(parts, trim(p):lower()) end
  local do_align  = (parts[1] or "yes") ~= "no"
  local do_folder = (parts[2] or "yes") ~= "no"
  local do_bus    = (parts[3] or "yes") ~= "no"

  -- ── Scan tracks ───────────────────────────────────────────────────────
  local groups = build_groups()

  if #groups == 0 then
    reaper.MB(
      "No stem groups found.\n\n"
      .. "This script looks for tracks whose source filenames contain stem-type\n"
      .. "keywords (vocals, drums, bass, guitar, instrumental, etc.).\n\n"
      .. "Ensure at least two stems from the same song are loaded.",
      SCRIPT_NAME, 0)
    return
  end

  -- ── Save state ────────────────────────────────────────────────────────
  local saved_cursor = reaper.GetCursorPosition()
  local sel_s, sel_e = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local n_aligned = 0
  local n_folders = 0
  local n_buses   = 0

  for _, group in ipairs(groups) do
    local song_name = group.song_name
    local ref_pos   = group.ref_pos  -- earliest item position in the group

    reaper.ShowConsoleMsg(
      ("[%s] Group: \"%s\"  (%d stems)\n")
      :format(SCRIPT_NAME, song_name, #group.tracks))

    -- ── Rename + color stem tracks ──────────────────────────────────────
    for _, entry in ipairs(group.tracks) do
      local tname = ("[Suno] %s (%s)"):format(song_name, entry.stem_label)
      reaper.GetSetMediaTrackInfo_String(entry.track, "P_NAME", tname, true)
      reaper.SetTrackColor(entry.track, native_color(entry.stem_color))
    end

    -- ── Align item start times ──────────────────────────────────────────
    if do_align then
      for _, entry in ipairs(group.tracks) do
        local delta = ref_pos - entry.ref_pos
        if math.abs(delta) > 0.0001 then
          shift_track_items(entry.track, delta)
          reaper.ShowConsoleMsg(
            ("  Shifted \"%s\" by %+.3f s\n"):format(entry.stem_label, delta))
          n_aligned = n_aligned + 1
        end
      end
    end

    -- ── Track indices (recomputed: earlier groups may have inserted tracks) ─
    local min_idx, max_idx, last_entry = math.huge, -1, nil
    for _, entry in ipairs(group.tracks) do
      local idx = reaper.GetMediaTrackInfo_Value(entry.track, "IP_TRACKNUMBER") - 1
      if idx >= 0 then
        if idx < min_idx then min_idx = idx end
        if idx > max_idx then max_idx, last_entry = idx, entry end
      end
    end

    -- A folder spans min_idx..max_idx. If anything else lives in that range it
    -- would be swallowed by the folder, so only wrap adjacent groups.
    local span       = (last_entry and (max_idx - min_idx + 1)) or 0
    local contiguous = (span == #group.tracks)

    -- Never re-purpose a track that is already part of a folder hierarchy.
    local depth_in_use = false
    for _, entry in ipairs(group.tracks) do
      if reaper.GetMediaTrackInfo_Value(entry.track, "I_FOLDERDEPTH") ~= 0 then
        depth_in_use = true
      end
    end

    -- ── Folder track ──────────────────────────────────────────────────────
    if do_folder then
      if not contiguous then
        reaper.ShowConsoleMsg(
          ("[%s] SKIP folder for \"%s\": its %d stems are not on adjacent tracks\n")
          :format(SCRIPT_NAME, song_name, #group.tracks))
      elseif depth_in_use then
        reaper.ShowConsoleMsg(
          ("[%s] SKIP folder for \"%s\": tracks are already in a folder hierarchy\n")
          :format(SCRIPT_NAME, song_name))
      else
        local folder_name  = "[Suno] " .. song_name
        local folder_track = insert_named_track(min_idx, folder_name, FOLDER_COLOR)
        if not folder_track then
          reaper.ShowConsoleMsg((("[%s] WARN: could not create folder for \"%s\"\n")
            :format(SCRIPT_NAME, song_name)))
        else
          -- depth=1 opens the folder: the next track is its first child.
          reaper.SetMediaTrackInfo_Value(folder_track, "I_FOLDERDEPTH", 1)

          -- Close the folder on the group's last stem (its live index shifted
          -- +1 because the folder track was just inserted above it).
          local last_track = reaper.GetTrack(0, max_idx + 1)
          if last_track then
            reaper.SetMediaTrackInfo_Value(last_track, "I_FOLDERDEPTH", -1)
            n_folders = n_folders + 1
          else
            -- Could not find the closing track: undo the open folder so the
            -- project is never left with an unbalanced hierarchy.
            reaper.SetMediaTrackInfo_Value(folder_track, "I_FOLDERDEPTH", 0)
            reaper.ShowConsoleMsg(
              ("[%s] WARN: folder for \"%s\" could not be closed; reverted\n")
              :format(SCRIPT_NAME, song_name))
          end
        end
      end
    end

    -- ── Summing bus ───────────────────────────────────────────────────────
    -- Independent of folder creation: the bus sits directly after the group's
    -- last stem (which is outside the folder, because that stem closes it).
    if do_bus and last_entry then
      local last_idx = reaper.GetMediaTrackInfo_Value(last_entry.track, "IP_TRACKNUMBER") - 1
      local bus_name  = ("[Suno] %s  [BUS]"):format(song_name)
      local bus_track = insert_named_track(last_idx + 1, bus_name, BUS_COLOR)
      if not bus_track then
        reaper.ShowConsoleMsg((("[%s] WARN: could not create bus for \"%s\"\n")
          :format(SCRIPT_NAME, song_name)))
      else
        local routed = 0
        for _, entry in ipairs(group.tracks) do
          local stem_idx   = reaper.GetMediaTrackInfo_Value(entry.track, "IP_TRACKNUMBER") - 1
          local stem_track = reaper.GetTrack(0, stem_idx)
          if stem_track and create_post_fader_send(stem_track, bus_track) then
            routed = routed + 1
          end
        end
        reaper.ShowConsoleMsg(
          ("  Bus created: \"%s\"  (%d/%d stems routed)\n")
          :format(bus_name, routed, #group.tracks))
        n_buses = n_buses + 1
      end
    end

  end

  -- ── Restore state ─────────────────────────────────────────────────────
  reaper.SetEditCurPos(saved_cursor, false, false)
  reaper.GetSet_LoopTimeRange(true, false, sel_s, sel_e, false)

  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock(SCRIPT_NAME .. " v" .. SCRIPT_VERSION, -1)
  reaper.UpdateArrange()
  reaper.TrackList_AdjustWindows(false)

  reaper.MB(
    ("Stem alignment complete!\n\n"
    .. "Groups found   : %d\n"
    .. "Tracks aligned : %d\n"
    .. "Folders created: %d\n"
    .. "Buses created  : %d\n\n"
    .. "Tip: use the bus fader to control the wet sum of each stem group.")
    :format(#groups, n_aligned, n_folders, n_buses),
    SCRIPT_NAME, 0)
end

Main()
