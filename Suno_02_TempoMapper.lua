-- @description Analyse a selected Suno audio item, estimate BPM, and insert a REAPER tempo marker
-- @author Scott Mills
-- @version 1.0.1
-- @changelog
--   1.0.1 (2026-11-13)
--     + Fix peak-cache call: MediaItemTake_GetPeaks does not exist in the
--       REAPER API; the correct function is GetMediaItemTake_Peaks
--     + Fix peak buffer layout (maximums block, then minimums block, interleaved)
--     + Fix peak start time: must be project time, not 0
--     + Mask the bit-packed return value (count lives in the low 20 bits)
--     + Guard marker now restores the previous project tempo instead of
--       repeating the new one
--     + Use SetTempoTimeSigMarker (AddTempoTimeSigMarker is deprecated)
--     + Robust parameter parsing (empty fields no longer shift the other fields)
--   1.0.0 (2026-05-23)
--     + Initial release
--     + Long-window energy contrast BPM detection
--     + Inserts tempo marker at item start position
--     + Aligns project grid to detected BPM
-- @provides [main] Suno_02_TempoMapper.lua
-- @about
--   ## Suno Tempo Mapper
--   Detects the BPM of a Suno audio item and sets the project tempo.
--
--   **What it does:**
--   Analyses the selected audio item to estimate its BPM
--   using an RMS-onset detection algorithm, then inserts a REAPER tempo marker
--   at the item start so the project grid aligns with the music. Also places
--   a guard marker at the end of the arrangement.
--
--   **Algorithm:**
--   1. Fetches peak data from REAPER's peak cache at 400 Hz resolution
--   2. Computes per-frame energy and differentiates for onset detection
--   3. Adaptive peak-picking with configurable sensitivity
--   4. Median inter-onset interval → BPM
--   5. Octave-correction into 70-160 BPM range (typical Suno output)
--
--   **Prerequisites:**
--   - REAPER 6.70+ (no external extensions required)
--   - Run after Suno_01_MetadataOrganizer
--   - A track containing an audio item with musical content
--
--   **How to use:**
--   1. Select a track with a Suno audio item
--   2. Run the script
--   3. The script detects BPM and sets the project tempo
--   4. Check the console for the detected BPM value
--
--   **Configuration (edit at top of script):**
--   - Override BPM: 0 = auto-detect; set to e.g. 128 to force that BPM (prompted at run time)
--   - Onset sensitivity: 0.1 = loose, 1.0 = strict (prompted at run time, default 0.35)
--
--   **Limitations:**
--   - Works best on full-mix audio with clear rhythmic content
--   - Sparse or ambient material may produce inaccurate detection
--   - Use the Override BPM prompt for material with ambiguous tempo
--[[============================================================================
  SCRIPT : Suno Tempo Mapper
  AUTHOR : TrackClear / SGM Studios
  VERSION: 1.0.0

  DESCRIPTION:
    Analyses a selected Suno audio item to estimate its BPM, then inserts a
    REAPER tempo marker at the item start so the project grid aligns with the
    music.

    Detection algorithm:
      1. Fetch peak data from REAPER's built-in peak cache at 400 Hz resolution
         (one value every 2.5 ms — sufficient for beat-level onset detection).
      2. Compute per-frame energy (squared peak = proxy for instantaneous power).
      3. Smooth with a Hann-weighted window (~25 ms), then differentiate.
      4. Half-wave rectify the derivative to get a positive onset detection
         function (ODF) that spikes at every transient/attack.
      5. Adaptive peak-picking: threshold = mean + sensitivity × std × 4.
      6. Compute inter-onset intervals (IOIs), take the median, derive BPM.
      7. Octave-correct into the 70–160 BPM range typical of Suno output.
      8. Present the result for confirmation — user can accept or override.

    Buffer layout for GetMediaItemTake_Peaks (want_extra_type = 0):
      buf[0 .. chans*ns-1]        = maximums, interleaved per channel
      buf[chans*ns .. 2*chans*ns-1] = minimums, interleaved per channel
      ns = numsamplesperchannel, NOT the return value.
    The return value is bit-packed: sample count in the low 20 bits
    (0xFFFFF), output mode in bits 20-23, extra-type flag in bit 24.
    starttime is a PROJECT time, not a take-relative time.

  DEPENDENCIES:
    REAPER 6.70+  (no external extensions required)
============================================================================]]--

local SCRIPT_NAME    = "Suno Tempo Mapper"
local SCRIPT_VERSION = "1.0.1"

-- ─── TUNEABLE CONSTANTS ──────────────────────────────────────────────────────
-- Peaks per second fetched from REAPER's peak cache.
-- 400 Hz → 2.5 ms resolution. Adequate for beats; going higher mostly adds noise.
local PEAKRATE       = 400

-- Onset detection: minimum gap between consecutive beats (seconds).
-- Prevents a single broad transient from triggering twice. 150 ms = 400 BPM max.
local MIN_ONSET_GAP  = 0.15

-- BPM search window.  Suno rarely goes outside 60–180, but we allow wider.
local BPM_MIN        = 40
local BPM_MAX        = 220

-- After placement, a "guard" tempo marker is inserted just past the item end
-- to prevent the new BPM bleeding into neighbouring content.
local ADD_GUARD_MARKER = true

-- ─── UTILITIES ───────────────────────────────────────────────────────────────

local function trim(s)  return s:match("^%s*(.-)%s*$") end

local function clamp(v, lo, hi)  return math.max(lo, math.min(hi, v)) end

-- Parse "a,b,c,d" into a fixed-size array of numbers.
-- Empty / non-numeric fields yield nil in their own slot, so one blank field
-- can never shift the meaning of the fields that follow it.
local function parse_numbers(csv, count)
  local out = {}
  local i = 1
  for field in (csv .. ","):gmatch("(.-),") do
    if i > count then break end
    local v = tonumber(trim(field))
    out[i] = v
    i = i + 1
  end
  return out
end

-- ─── PEAK CACHE ACCESS ──────────────────────────────────────────────────────
-- Official API (SDK: reaper_plugin_functions.h):
--   integer GetMediaItemTake_Peaks(MediaItem_Take take, number peakrate,
--       number starttime, integer numchannels, integer numsamplesperchannel,
--       integer want_extra_type, reaper.array buf)
-- Notes that matter:
--   * starttime is PROJECT time (an item at 10 s must pass 10, not 0).
--   * buf is two blocks of numchannels*numsamplesperchannel doubles:
--     maximums first, then minimums, each interleaved per channel.
--   * the return value is bit-packed; the sample count is retval & 0xFFFFF.
local PEAK_COUNT_MASK = 0xFFFFF

local function fetch_peaks(take, item_pos, peakrate, num_chans, nsamples)
  local buf = reaper.new_array(num_chans * nsamples * 2)
  buf.clear()
  local ret = reaper.GetMediaItemTake_Peaks(
    take, peakrate, item_pos, num_chans, nsamples, 0, buf)
  local n = ret & PEAK_COUNT_MASK
  if n > nsamples then n = nsamples end
  return buf, n
end

-- Peak amplitude (max |max|, |min|) of frame `s` on channel `c` (both 1-based).
local function frame_amp(buf, nsamples, num_chans, s, c)
  local base = (s - 1) * num_chans + (c - 1)
  local hi = buf[base + 1]
  local lo = buf[num_chans * nsamples + base + 1]
  if lo < 0 then lo = -lo end
  return (hi > lo) and hi or lo
end

-- Median of a numeric array (non-destructive).
local function median(arr)
  if #arr == 0 then return nil end
  local s = {}
  for _, v in ipairs(arr) do table.insert(s, v) end
  table.sort(s)
  return s[math.ceil(#s / 2)]
end

-- ─── ONSET DETECTION ─────────────────────────────────────────────────────────

-- Fetch audio peaks and compute a list of onset times (seconds from item start).
-- sensitivity: [0.1, 1.0].  Lower = more onsets detected; higher = only strong beats.
-- Returns (onsets_table, err_string).  err_string is nil on success.
local function detect_onsets(take, item_pos, item_length, sensitivity)
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return nil, "The active take has no media source." end

  local num_chans = math.min(2, reaper.GetMediaSourceNumChannels(src))
  if not num_chans or num_chans < 1 then num_chans = 1 end
  local n_req = math.ceil(item_length * PEAKRATE)

  if n_req < 8 then
    return nil, "Item is too short to analyse (need at least 20 ms)."
  end

  local buf, n = fetch_peaks(take, item_pos, PEAKRATE, num_chans, n_req)

  if n < 8 then
    return nil,
      "Peak data unavailable. The item may need to be rendered / built peak cache first.\n"
      .. "(Build peaks: right-click item → Build missing peaks.)"
  end

  -- Mix channels to a mono energy signal: E[s] = mean of peak_c[s]^2
  local energy = {}
  for s = 1, n do
    local e = 0.0
    for c = 1, num_chans do
      local v = frame_amp(buf, n_req, num_chans, s, c)
      e = e + v * v
    end
    energy[s] = e / num_chans
  end

  -- Hann-weighted smoothing over ±HALF_WIN frames (~25 ms total window)
  local HALF_WIN = math.floor(0.0125 * PEAKRATE)   -- 5 at 400 Hz
  local smoothed = {}
  for s = 1, n do
    local sum, w_tot = 0.0, 0.0
    for k = -HALF_WIN, HALF_WIN do
      local idx = s + k
      if idx >= 1 and idx <= n then
        -- Hann coefficient: cos²(π·k / (2·HALF_WIN))
        local w = math.cos(math.pi * k / (2 * HALF_WIN))
        w       = w * w
        sum     = sum + energy[idx] * w
        w_tot   = w_tot + w
      end
    end
    smoothed[s] = (w_tot > 0) and (sum / w_tot) or 0.0
  end

  -- Onset detection function: positive half-wave rectified first derivative
  local odf    = { 0.0 }
  local odf_max = 0.0
  for s = 2, n do
    local v = math.max(0.0, smoothed[s] - smoothed[s - 1])
    odf[s]  = v
    if v > odf_max then odf_max = v end
  end

  if odf_max < 1e-9 then
    return nil, "Audio appears to be silent or too quiet to analyse."
  end

  -- Normalise ODF to [0, 1]
  for s = 1, n do odf[s] = odf[s] / odf_max end

  -- Adaptive threshold: mean(ODF) + sensitivity × std(ODF) × 4
  local sum_odf = 0.0
  for _, v in ipairs(odf) do sum_odf = sum_odf + v end
  local mean_odf = sum_odf / n

  local var = 0.0
  for _, v in ipairs(odf) do var = var + (v - mean_odf)^2 end
  local std_odf = math.sqrt(var / n)

  local threshold = mean_odf + clamp(sensitivity, 0.1, 1.0) * std_odf * 4.0

  -- Peak-pick: local maxima above threshold, enforcing MIN_ONSET_GAP
  local onsets  = {}
  local min_gap = math.floor(MIN_ONSET_GAP * PEAKRATE)
  local last    = -(min_gap + 1)

  for s = 2, n - 1 do
    if odf[s] > threshold
      and odf[s] >= odf[s - 1]
      and odf[s] >= odf[s + 1]
      and (s - last) >= min_gap
    then
      table.insert(onsets, (s - 1) / PEAKRATE)
      last = s
    end
  end

  return onsets, nil
end

-- ─── BPM ESTIMATION ──────────────────────────────────────────────────────────

-- Derive BPM from onset times via median inter-onset interval.
local function estimate_bpm(onsets)
  if not onsets or #onsets < 4 then return nil end

  local iois = {}
  for i = 2, #onsets do
    local ioi = onsets[i] - onsets[i - 1]
    -- Clamp to the BPM search range (converted to seconds)
    if ioi >= (60 / BPM_MAX) and ioi <= (60 / BPM_MIN) then
      table.insert(iois, ioi)
    end
  end
  if #iois < 3 then return nil end

  local med = median(iois)
  if not med or med == 0 then return nil end

  local bpm = 60.0 / med

  -- Fold into Suno's typical range (70–160 BPM) via octave correction
  while bpm < 70  and bpm * 2 <= BPM_MAX do bpm = bpm * 2 end
  while bpm > 160 and bpm / 2 >= BPM_MIN do bpm = bpm / 2 end

  -- Round to one decimal place
  return math.floor(bpm * 10 + 0.5) / 10
end

-- ─── INIT ───────────────────────────────────────────────────────────────────

local function init()
  if reaper.CountSelectedMediaItems(0) == 0 then
    reaper.MB(
      "No item selected.\n\nSelect a Suno audio item and run this script again.",
      SCRIPT_NAME, 0)
    return false
  end
  local item = reaper.GetSelectedMediaItem(0, 0)
  local take = reaper.GetActiveTake(item)
  if not take then
    reaper.MB("The selected item has no active take.", SCRIPT_NAME, 0)
    return false
  end
  if reaper.TakeIsMIDI(take) then
    reaper.MB("This script works on audio items, not MIDI takes.", SCRIPT_NAME, 0)
    return false
  end
  return true
end

-- ─── MAIN ───────────────────────────────────────────────────────────────────

-- Return the tempo / time signature in effect at `timepos`.
local function tempo_at(timepos)
  local best = nil
  for i = 0, reaper.CountTempoTimeSigMarkers(0) - 1 do
    local _, pos, _mp, _bp, bpm, num, den = reaper.GetTempoTimeSigMarker(0, i)
    if pos <= timepos + 1e-9 then
      best = { pos = pos, bpm = bpm, num = num, den = den }
    end
  end
  if best then return best end
  local bpm, bpi = reaper.GetProjectTimeSignature2(0)
  return { pos = 0, bpm = bpm or 120, num = bpi or 4, den = 4 }
end

local function Main()
  if not init() then return end

  local item     = reaper.GetSelectedMediaItem(0, 0)
  local take     = reaper.GetActiveTake(item)
  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

  -- ── Gather user parameters ────────────────────────────────────────────
  local ok, csv = reaper.GetUserInputs(SCRIPT_NAME, 4,
    "Onset sensitivity (0.1=loose  1.0=strict),"
    .. "Time signature: beats per bar,"
    .. "Time signature: beat unit (4=quarter),"
    .. "Override BPM (0 = auto-detect):",
    "0.35,4,4,0")
  if not ok then return end

  local params = parse_numbers(csv, 4)
  local sensitivity  = clamp(params[1] or 0.35, 0.1, 1.0)
  local timesig_num  = math.max(1, math.floor(params[2] or 4))
  local timesig_den  = math.max(1, math.floor(params[3] or 4))
  local override_bpm = params[4] or 0

  -- ── Determine final BPM ───────────────────────────────────────────────
  local final_bpm

  if override_bpm > 0 then
    final_bpm = override_bpm
    reaper.ShowConsoleMsg(("[%s] Using manual BPM: %.2f\n"):format(SCRIPT_NAME, final_bpm))
  else
    reaper.ShowConsoleMsg(("[%s] Analysing audio peaks…\n"):format(SCRIPT_NAME))
    local onsets, detect_err = detect_onsets(take, item_pos, item_len, sensitivity)

    local default_bpm_str = "120"
    local confirm_prompt

    if detect_err then
      reaper.ShowConsoleMsg(("[%s] WARN: %s\n"):format(SCRIPT_NAME, detect_err))
      confirm_prompt = "Auto-detect failed:\n" .. detect_err .. "\n\nEnter BPM manually:"
    else
      local detected = estimate_bpm(onsets)
      reaper.ShowConsoleMsg(
        ("[%s] Detected %d onsets → estimated %.1f BPM\n")
        :format(SCRIPT_NAME, onsets and #onsets or 0, detected or 0))
      default_bpm_str = detected and tostring(detected) or "120"
      confirm_prompt  = ("Detected %s BPM  (from %d onset(s))\n"
        .. "Edit if needed, then click OK:")
        :format(default_bpm_str, onsets and #onsets or 0)
    end

    local ok2, bpm_str = reaper.GetUserInputs(
      SCRIPT_NAME .. " – Confirm BPM", 1, confirm_prompt, default_bpm_str)
    if not ok2 then return end

    final_bpm = tonumber(trim(bpm_str)) or tonumber(default_bpm_str) or 120
  end

  -- Validate
  if final_bpm < BPM_MIN or final_bpm > BPM_MAX then
    reaper.MB(
      ("BPM %.1f is outside the supported range (%d–%d).\n"
      .. "Please run the script again and enter a valid value.")
      :format(final_bpm, BPM_MIN, BPM_MAX),
      SCRIPT_NAME, 0)
    return
  end

  -- ── Apply tempo markers ───────────────────────────────────────────────
  local saved_cursor = reaper.GetCursorPosition()

  -- Capture the tempo / time signature in effect at the item start BEFORE any
  -- changes, so the guard marker can restore it after the item.
  local prev_tempo  = tempo_at(item_pos)
  local guard_added = false

  -- End of the arrangement (only needed to decide whether a guard is useful).
  local project_end = 0
  for ti = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, ti)
    for ii = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local it = reaper.GetTrackMediaItem(tr, ii)
      local ep = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
           + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
      if ep > project_end then project_end = ep end
    end
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- Remove any existing tempo markers that fall inside this item's time range
  -- (avoids conflicting markers from previous runs).
  local removed = 0
  for mi = reaper.CountTempoTimeSigMarkers(0) - 1, 0, -1 do
    local _, tpos = reaper.GetTempoTimeSigMarker(0, mi)
    if tpos >= item_pos and tpos < item_pos + item_len then
      reaper.DeleteTempoTimeSigMarker(0, mi)
      removed = removed + 1
    end
  end

  -- Primary marker at item start. ptidx = -1 inserts a new marker;
  -- AddTempoTimeSigMarker is deprecated in favour of this call.
  reaper.SetTempoTimeSigMarker(0, -1, item_pos, -1, -1,
    final_bpm, timesig_num, timesig_den, false)

  -- Optional guard marker just after item end: restores the tempo that was in
  -- force before this item, so the new BPM cannot leak into neighbouring songs.
  if ADD_GUARD_MARKER then
    local guard_t = item_pos + item_len
    if guard_t < project_end - 0.01 then
      reaper.SetTempoTimeSigMarker(0, -1, guard_t, -1, -1,
        prev_tempo.bpm, prev_tempo.num, prev_tempo.den, false)
      guard_added = true
    end
  end

  reaper.SetEditCurPos(saved_cursor, false, false)
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock(
    (SCRIPT_NAME .. " v" .. SCRIPT_VERSION .. ": %.2f BPM @ %.3fs")
    :format(final_bpm, item_pos), -1)
  reaper.UpdateArrange()
  reaper.UpdateTimeline()

  reaper.MB(
    ("Tempo map applied!\n\n"
    .. "BPM          : %.2f\n"
    .. "Time sig     : %d/%d\n"
    .. "Item start   : %.3f s\n"
    .. "Markers removed : %d (prior)\n"
    .. (guard_added and ("Guard marker : tempo restored to %.2f at %.3fs\n")
          :format(prev_tempo.bpm, item_pos + item_len) or ""))
    :format(final_bpm, timesig_num, timesig_den, item_pos, removed),
    SCRIPT_NAME, 0)
end

Main()
