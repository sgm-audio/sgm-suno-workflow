-- @description Split Suno audio items at structural boundaries (verse/chorus/bridge) using energy contrast
-- @author Scott Mills
-- @version 1.0.0
-- @changelog
--   1.0.0 (2026-05-23)
--     + Initial release
--     + Long-window energy contrast structural detection
--     + Splits at section boundaries, not individual beat onsets
--     + Adds section markers at each split point
-- @provides
--   [main] Suno_03_DynamicSplitter.lua
-- @about
--   ## Suno Dynamic Splitter
--   Splits Suno audio items at musically significant structural transitions
--   (verse/chorus/bridge) using long-window energy contrast detection.
--
--   **What it does:**
--   Analyses audio items for section boundaries and splits them at those
--   points. Uses a rolling RMS energy contrast method: when short-frame RMS
--   rises above the long-window average, a section transition is detected.
--   Each new item is named "[original name] — Sec 01", "— Sec 02", etc.
--
--   **The algorithm:**
--   1. Divides the item into ~50ms frames for energy measurement
--   2. Computes a moving RMS over a ~4s window as "background" level
--   3. Detects transitions where energy/density/spectral character changes
--   4. Enforces minimum section length (default 8s) to avoid beat-level chopping
--   5. Splits right-to-left to prevent item drift from REAPER's split behavior
--
--   **Prerequisites:**
--   - REAPER 6.70+ (no external extensions required)
--   - Run after Suno_02_TempoMapper
--   - Audio items with clear section changes
--
--   **How to use:**
--   1. Select the track(s) containing Suno items to split
--   2. Run the script
--   3. Enter sensitivity (0.1–1.0) and minimum section length when prompted
--   4. Items are split at detected boundaries
--
--   **Configuration (edit at top of script):**
--   - DEFAULT_SENSITIVITY = "0.40": lower = more splits, higher = fewer
--   - DEFAULT_MIN_SECTION = "8.0": minimum section length in seconds
--   - DEFAULT_MAX_SECTIONS = "12": hard cap on total sections
--
--   **Limitations:**
--   - Works best on material with distinct section energy changes
--   - Very uniform/ambient material may produce few or no splits
--   - Minimum section length prevents over-splitting but may miss quick transitions
--[[============================================================================
  SCRIPT : Suno Dynamic Splitter
  AUTHOR : TrackClear / SGM Studios
  VERSION: 1.0.0

  DESCRIPTION:
    Splits selected Suno audio items at structurally significant boundaries
    (verse/chorus/bridge transitions) rather than at individual beat onsets.

    The algorithm uses a LONG-WINDOW energy contrast detector:
      1. Divide the item into SHORT_FRAMES (~50 ms) for energy measurement.
      2. Compute a moving RMS over LONG_WINDOW (~4 s) as a "background" level.
      3. An onset occurs where the short-frame RMS rises well above the
         long-window average — i.e., at section transitions where energy,
         density, or spectral character changes dramatically.
      4. Enforce a minimum section length (user-configurable, default 8 s) so
         the script does not chop individual beats.
      5. Call reaper.SplitMediaItem at each detected boundary.

    After splitting, each new item is named with a section suffix:
    "[original name] – Sec 01", "– Sec 02", etc.

  DEPENDENCIES:
    REAPER 6.70+  (no external extensions required)
============================================================================]]--

local SCRIPT_NAME    = "Suno Dynamic Splitter"
local SCRIPT_VERSION = "1.0.0"

-- ─── TUNEABLE DEFAULTS ────────────────────────────────────────────────────────

local DEFAULT_SENSITIVITY  = "0.40"   -- 0.1 (loose) – 1.0 (strict)
local DEFAULT_MIN_SECTION  = "8.0"    -- minimum section length in seconds
local DEFAULT_MAX_SECTIONS = "12"     -- hard cap; keeps edits manageable

-- Peak analysis resolutions (Hz)
local SHORT_FRAME_RATE = 20    -- 20 Hz → 50 ms per short frame
local LONG_WIN_SECS    = 4.0   -- seconds of history for the moving average

-- ─── UTILITIES ───────────────────────────────────────────────────────────────

local function trim(s) return s:match("^%s*(.-)%s*$") end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- Return the active take name of an item (empty string if none).
local function take_name(item)
  local take = reaper.GetActiveTake(item)
  if not take then return "" end
  local _, name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
  return name or ""
end

-- Set the take name on an item's active take.
local function set_take_name(item, name)
  local take = reaper.GetActiveTake(item)
  if take then
    reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", name, true)
  end
end

-- ─── SECTION BOUNDARY DETECTION ──────────────────────────────────────────────
--
-- Returns an array of split times (seconds from project start), or nil + error.

local function detect_boundaries(take, item_pos, item_len, sensitivity, min_section_secs)
  local src       = reaper.GetMediaItemTake_Source(take)
  local num_chans = math.min(2, reaper.GetMediaSourceNumChannels(src))
  local n_frames  = math.ceil(item_len * SHORT_FRAME_RATE)

  if n_frames < 4 then
    return nil, "Item is too short to analyse."
  end

  -- Fetch peaks at SHORT_FRAME_RATE resolution (1 value per frame per channel)
  local buf = reaper.new_array(num_chans * n_frames)
  local n   = reaper.MediaItemTake_GetPeaks(
                take, SHORT_FRAME_RATE, 0, num_chans, n_frames, 0, buf)

  if n < 4 then
    return nil,
      "Could not read peak data.\n"
      .. "Ensure the item has a built peak cache (right-click item → Build missing peaks)."
  end

  -- Per-frame energy: mean(peak_c^2) across channels
  local energy = {}
  for s = 1, n do
    local e = 0.0
    for c = 0, num_chans - 1 do
      local v = buf[c * n + s]
      e = e + v * v
    end
    energy[s] = e / num_chans
  end

  -- Long-window moving average RMS (the "background" energy level)
  local long_win_frames = math.max(2, math.floor(LONG_WIN_SECS * SHORT_FRAME_RATE))
  local long_avg        = {}
  for s = 1, n do
    local lo  = math.max(1, s - long_win_frames)
    local hi  = math.min(n, s + long_win_frames)
    local sum = 0.0
    for k = lo, hi do sum = sum + energy[k] end
    long_avg[s] = sum / (hi - lo + 1)
  end

  -- Contrast: ratio of short-frame energy to long-window average
  -- A value >> 1.0 means "this frame is much louder than the surrounding average"
  local contrast  = {}
  local cont_max  = 0.0
  for s = 1, n do
    local av = long_avg[s]
    local c  = (av > 1e-9) and (energy[s] / av) or 1.0
    contrast[s] = c
    if c > cont_max then cont_max = c end
  end

  -- Normalise contrast and compute its first derivative (ODF)
  local odf     = { 0.0 }
  local odf_max = 0.0
  for s = 2, n do
    local v = math.max(0.0, contrast[s] - contrast[s - 1])
    odf[s]  = v
    if v > odf_max then odf_max = v end
  end
  if odf_max < 1e-9 then
    return nil, "Audio shows no detectable energy variation — cannot split."
  end
  for s = 1, n do odf[s] = odf[s] / odf_max end

  -- Adaptive threshold (same formula as TempoMapper but with a higher multiplier
  -- so only large structural changes trigger, not individual beats)
  local sum_o = 0.0
  for _, v in ipairs(odf) do sum_o = sum_o + v end
  local mean_o = sum_o / n
  local var    = 0.0
  for _, v in ipairs(odf) do var = var + (v - mean_o)^2 end
  local std_o = math.sqrt(var / n)

  -- sensitivity maps to [6, 2] multiplier range (lower sensitivity = higher bar)
  local mult      = 6.0 - clamp(sensitivity, 0.1, 1.0) * 4.0
  local threshold = mean_o + mult * std_o

  -- Min gap in frames
  local min_gap = math.max(1, math.floor(min_section_secs * SHORT_FRAME_RATE))

  -- Peak-picking
  local boundaries = {}
  local last_idx   = -min_gap

  for s = 2, n - 1 do
    if odf[s] > threshold
      and odf[s] >= odf[s - 1]
      and odf[s] >= odf[s + 1]
      and (s - last_idx) >= min_gap
    then
      -- Convert frame index to project time
      local t = item_pos + (s - 1) / SHORT_FRAME_RATE
      table.insert(boundaries, t)
      last_idx = s
    end
  end

  return boundaries, nil
end

-- ─── INIT ────────────────────────────────────────────────────────────────────

local function init()
  if reaper.CountSelectedMediaItems(0) == 0 then
    reaper.MB(
      "No item(s) selected.\n\nSelect one or more Suno audio items and try again.",
      SCRIPT_NAME, 0)
    return false
  end
  return true
end

-- ─── MAIN ────────────────────────────────────────────────────────────────────

local function Main()
  if not init() then return end

  -- ── User parameters ───────────────────────────────────────────────────
  local ok, csv = reaper.GetUserInputs(SCRIPT_NAME, 3,
    "Split sensitivity (0.1=loose  1.0=strict),"
    .. "Minimum section length (seconds),"
    .. "Maximum number of splits:",
    DEFAULT_SENSITIVITY .. "," .. DEFAULT_MIN_SECTION .. "," .. DEFAULT_MAX_SECTIONS)
  if not ok then return end

  local params = {}
  for p in csv:gmatch("[^,]+") do
    table.insert(params, tonumber(trim(p)) or 0)
  end
  local sensitivity  = clamp(params[1] or 0.40, 0.1, 1.0)
  local min_section  = math.max(1.0, params[2] or 8.0)
  local max_splits   = math.max(1, math.floor(params[3] or 12))

  -- ── Save edit state ───────────────────────────────────────────────────
  local saved_cursor = reaper.GetCursorPosition()
  local sel_s, sel_e = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local total_splits = 0
  local total_errors = 0
  local n_items      = reaper.CountSelectedMediaItems(0)

  -- Collect items before splitting (splitting invalidates the selection count)
  local items = {}
  for i = 0, n_items - 1 do
    table.insert(items, reaper.GetSelectedMediaItem(0, i))
  end

  for _, item in ipairs(items) do
    local take = reaper.GetActiveTake(item)
    if not take or reaper.TakeIsMIDI(take) then
      total_errors = total_errors + 1
      goto next_item
    end

    local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local orig_name = take_name(item)

    reaper.ShowConsoleMsg(
      ("[%s] Analysing: %s (%.1f s)\n"):format(SCRIPT_NAME, orig_name, item_len))

    local boundaries, err = detect_boundaries(
      take, item_pos, item_len, sensitivity, min_section)

    if err then
      reaper.ShowConsoleMsg(("[%s] WARN: %s\n"):format(SCRIPT_NAME, err))
      total_errors = total_errors + 1
      goto next_item
    end

    if #boundaries == 0 then
      reaper.ShowConsoleMsg(("[%s] No split points found in this item.\n"):format(SCRIPT_NAME))
      goto next_item
    end

    -- Cap to max_splits
    while #boundaries > max_splits do
      table.remove(boundaries, #boundaries)
    end

    reaper.ShowConsoleMsg(
      ("[%s] Found %d boundary/ies.\n"):format(SCRIPT_NAME, #boundaries))

    -- Split from right-to-left so item references stay valid
    -- after each split (the left portion retains the original handle).
    table.sort(boundaries, function(a, b) return a > b end)

    local current_item = item
    local section_idx  = #boundaries + 1  -- work backwards

    for _, split_t in ipairs(boundaries) do
      -- Snap split time to the nearest millisecond to avoid floating-point drift
      split_t = math.floor(split_t * 1000 + 0.5) / 1000

      -- Clamp to within the current item
      local cur_pos = reaper.GetMediaItemInfo_Value(current_item, "D_POSITION")
      local cur_len = reaper.GetMediaItemInfo_Value(current_item, "D_LENGTH")
      if split_t <= cur_pos + 0.001 or split_t >= cur_pos + cur_len - 0.001 then
        goto next_split
      end

      local right_item = reaper.SplitMediaItem(current_item, split_t)
      if not right_item then
        reaper.ShowConsoleMsg(
          ("[%s] WARN: SplitMediaItem failed at %.3f s\n"):format(SCRIPT_NAME, split_t))
        goto next_split
      end

      -- Name the right (later) item
      local sec_name = (orig_name ~= "" and (orig_name .. " – ") or "")
                       .. ("Sec %02d"):format(section_idx)
      set_take_name(right_item, sec_name)

      section_idx  = section_idx - 1
      total_splits = total_splits + 1

      ::next_split::
    end

    -- Name the first (leftmost) item
    local first_name = (orig_name ~= "" and (orig_name .. " – ") or "") .. "Sec 01"
    set_take_name(current_item, first_name)

    ::next_item::
  end

  -- ── Restore edit state ────────────────────────────────────────────────
  reaper.SetEditCurPos(saved_cursor, false, false)
  reaper.GetSet_LoopTimeRange(true, false, sel_s, sel_e, false)

  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock(SCRIPT_NAME .. " v" .. SCRIPT_VERSION, -1)
  reaper.UpdateArrange()

  local msg = ("Split complete!\n\n"
    .. "Items analysed : %d\n"
    .. "Splits made    : %d\n"
    .. "Errors/skipped : %d\n\n"
    .. "Tip: drag split points in the arrange view to fine-tune section boundaries.")
    :format(n_items, total_splits, total_errors)
  reaper.MB(msg, SCRIPT_NAME, 0)
end

Main()
