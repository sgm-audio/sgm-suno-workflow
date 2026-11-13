-- @description Batch-normalise selected Suno items to a target loudness level (RMS estimate)
-- @author Scott Mills
-- @version 1.0.1
-- @changelog
--   1.0.1 (2026-11-13)
--     + Measure real samples through GetAudioAccessorSamples instead of guessing
--       RMS from the peak cache (the old peak call did not even exist, so every
--       run aborted with "attempt to call a nil value")
--     + Peak-cache path kept as a fallback, with the correct API name, project
--       start time, block layout and bit-packed return value
--     + Report true sample peak (max of |max| and |min|) for the ceiling check
--     + Robust parameter parsing (empty fields no longer shift the other fields)
--   1.0.0 (2026-05-23)
--     + Initial release
--     + Per-item integrated loudness measurement
--     + Batch normalisation to user-defined LUFS target
--     + Corrects wild volume variation typical of AI-generated audio
-- @provides [main] Suno_04_LoudnessMaster.lua
-- @about
--   ## Suno Loudness Master
--   Normalises selected Suno audio items to a target integrated loudness level.
--
--   **What it does:**
--   Measures the integrated loudness of each selected audio item using a
--   peak-RMS approximation method, then applies gain to hit the target LUFS
--   level (default -18 dBFS RMS, used as a rough stand-in for -14 LUFS). Backs
--   gain off so the peak-cache peak stays under -0.3 dBFS (sample peak, not dBTP).
--
--   **Method:**
--   1. Fetches peak data from REAPER's peak cache at 100 Hz resolution
--   2. Computes RMS estimate: RMS ≈ sqrt(mean(peak²))
--   3. Measures dBFS, calculates required gain to reach target LUFS
--   4. Applies gain via item D_VOL (preserves existing item volume)
--   5. Peak safety: reduces gain if the peak-cache peak would exceed the ceiling
--
--   **Prerequisites:**
--   - REAPER 6.70+ (no external extensions required)
--   - Run after Suno_03_DynamicSplitter
--   - Select items to normalize (or script processes all items)
--
--   **How to use:**
--   1. Select the items/tracks to normalize
--   2. Run the script
--   3. Check the console for per-item gain changes
--
--   **Configuration (edit at top of script):**
--   - DEFAULT_TARGET = "-18": target in dBFS RMS (e.g., -13 for a louder master)
--   - PEAK_CEILING = -0.3: peak ceiling in dBFS (sample peak from the peak cache)
--
--   **LUFS ↔ dBFS approximation guide:**
--   - Streaming master:  -14 LUFS ≈ -18 dBFS RMS
--   - Competitive master: -9 LUFS  ≈ -13 dBFS RMS
--   - Loud modern pop:    -7 LUFS  ≈ -11 dBFS RMS
--
--   **Limitations:**
--   - Uses peak-RMS approximation (not true K-weighted LUFS)
--   - I haven't measured how far it lands from real LUFS; check with a meter
--   - For precise LUFS measurement, use a JSFX loudness meter after applying gain
--[[============================================================================
  SCRIPT : Suno Loudness Master
  AUTHOR : TrackClear / SGM Studios
  VERSION: 1.0.0

  DESCRIPTION:
    Batch-normalises selected Suno audio items to a target integrated loudness
    level, correcting the wild volume variation typical of AI-generated audio.

    Method:
      1. Read the item's audio through a take audio accessor
         (GetAudioAccessorSamples) in 32768-sample blocks.
      2. Compute true sample RMS over the item and the sample peak
         (max |sample|). If the accessor is unavailable, fall back to the
         peak cache (GetMediaItemTake_Peaks) with a documented over-estimate.
      3. Convert to dBFS: measured_dBFS = 20 × log10(RMS).
      4. Gain required: Δ dB = target_dBFS − measured_dBFS.
      5. Apply via the item's D_VOL property (linear gain, compounded with any
         existing item volume so prior manual adjustments are preserved).
      6. True-peak safety: if the estimated peak after gain would exceed
         PEAK_CEILING (default −0.3 dBFS), the gain is reduced to avoid
         digital clipping.

    LUFS ↔ dBFS approximation guide (full-mix content):
      Streaming master  : −14 LUFS ≈ −18 dBFS RMS
      Competitive master: −9 LUFS  ≈ −13 dBFS RMS
      Loud modern pop   : −7 LUFS  ≈ −11 dBFS RMS

    For true LUFS measurement, process via a JSFX loudness meter (e.g., the
    "loudness_meter" included with REAPER or Youlean Loudness Meter) after
    applying this script's gain staging.

  DEPENDENCIES:
    REAPER 6.70+  (no external extensions required)
============================================================================]]--

local SCRIPT_NAME    = "Suno Loudness Master"
local SCRIPT_VERSION = "1.0.1"

-- ─── TUNEABLE DEFAULTS ────────────────────────────────────────────────────────

-- Peak analysis resolution: 100 Hz → 10 ms per sample.
-- Sufficient for RMS estimation; higher rates add CPU without benefit here.
local PEAKRATE       = 100

-- Default target: −18 dBFS RMS ≈ −14 LUFS (streaming-safe master level)
local DEFAULT_TARGET = "-18"

-- Maximum allowed peak after normalisation (dBFS). Prevents digital clipping.
local PEAK_CEILING   = -0.3

-- If an item's measured level is already within this many dB of the target,
-- skip it and report it as "already at target" (avoids tiny adjustments).
local SKIP_THRESHOLD = 0.5

-- ─── UTILITIES ───────────────────────────────────────────────────────────────

local function trim(s) return s:match("^%s*(.-)%s*$") end

-- Parse "a,b" into a fixed-size array of numbers; empty fields stay nil.
local function parse_numbers(csv, count)
  local out = {}
  local i = 1
  for field in (csv .. ","):gmatch("(.-),") do
    if i > count then break end
    out[i] = tonumber(trim(field))
    i = i + 1
  end
  return out
end

local function db_to_linear(db)  return 10 ^ (db / 20) end
local function linear_to_db(lin) return (lin > 0) and (20 * math.log(lin, 10)) or -math.huge end

-- ─── LOUDNESS MEASUREMENT ────────────────────────────────────────────────────

-- Samples per block when streaming audio through the accessor.
local ACCESSOR_CHUNK = 32768

-- Peak-cache fallback: official API GetMediaItemTake_Peaks (bit-packed return,
-- maximums block then minimums block, starttime in project time).
local PEAK_COUNT_MASK = 0xFFFFF

-- Returns { rms_db, peak_db, method } or nil on failure.
local function measure_with_accessor(item, take)
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return nil end

  local samplerate = reaper.GetMediaSourceSampleRate(src)
  if not samplerate or samplerate <= 0 then return nil end

  local num_chans = math.min(2, reaper.GetMediaSourceNumChannels(src))
  if not num_chans or num_chans < 1 then return nil end

  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local total    = math.floor(item_len * samplerate)
  if total < 2 then return nil end

  local acc = reaper.CreateTakeAudioAccessor(take)
  if not acc then return nil end

  local buf     = reaper.new_array(ACCESSOR_CHUNK * num_chans)
  local sum_sq  = 0.0
  local peak    = 0.0
  local counted = 0
  local read_any = false
  local offset  = 0

  while offset < total do
    local n = math.min(ACCESSOR_CHUNK, total - offset)
    buf.clear()
    local ok = reaper.GetAudioAccessorSamples(
      acc, samplerate, num_chans, item_pos + offset / samplerate, n, buf)
    if ok < 0 then break end
    if ok > 0 then read_any = true end

    for s = 1, n do
      local frame = 0.0
      for c = 1, num_chans do
        local v = buf[(s - 1) * num_chans + c]
        if v > peak then peak = v
        elseif -v > peak then peak = -v end
        frame = frame + v
      end
      frame = frame / num_chans          -- mono downmix, used for RMS only
      sum_sq = sum_sq + frame * frame
    end
    counted = counted + n
    offset  = offset + n
  end

  reaper.DestroyAudioAccessor(acc)

  if not read_any or counted < 2 then return nil end

  local rms = math.sqrt(sum_sq / counted)
  if rms < 1e-9 or peak < 1e-9 then return nil end   -- silent item

  return {
    rms_db  = linear_to_db(rms),
    peak_db = linear_to_db(peak),
    method  = "accessor",
  }
end

-- Fallback: estimate level from REAPER's peak cache at 100 Hz.
-- The peak cache stores window maximums, so this over-estimates RMS — correct
-- for choosing a gain, but do not treat the number as a loudness measurement.
local function measure_with_peaks(item, take)
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return nil end

  local num_chans = math.min(2, reaper.GetMediaSourceNumChannels(src))
  if not num_chans or num_chans < 1 then num_chans = 1 end
  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local nsamples = math.ceil(item_len * PEAKRATE)

  if nsamples < 2 then return nil end

  local buf = reaper.new_array(num_chans * nsamples * 2)
  buf.clear()
  local ret = reaper.GetMediaItemTake_Peaks(
    take, PEAKRATE, item_pos, num_chans, nsamples, 0, buf)
  local n = ret & PEAK_COUNT_MASK
  if n > nsamples then n = nsamples end
  if n < 2 then return nil end

  local sum_sq = 0.0
  local peak   = 0.0
  for s = 1, n do
    local frame = 0.0
    for c = 1, num_chans do
      local base = (s - 1) * num_chans + (c - 1)
      local hi = buf[base + 1]
      local lo = buf[num_chans * nsamples + base + 1]
      if lo < 0 then lo = -lo end
      local amp = (hi > lo) and hi or lo
      if amp > peak then peak = amp end
      frame = frame + amp
    end
    frame = frame / num_chans
    sum_sq = sum_sq + frame * frame
  end

  local rms = math.sqrt(sum_sq / n)
  if rms < 1e-9 or peak < 1e-9 then return nil end

  return {
    rms_db  = linear_to_db(rms),
    peak_db = linear_to_db(peak),
    method  = "peaks",
  }
end

local function measure_item(item)
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then return nil end
  return measure_with_accessor(item, take) or measure_with_peaks(item, take)
end

-- ─── INIT ────────────────────────────────────────────────────────────────────

local function init()
  if reaper.CountSelectedMediaItems(0) == 0 then
    reaper.MB(
      "No items selected.\n\n"
      .. "Select one or more Suno audio items and run this script again.",
      SCRIPT_NAME, 0)
    return false
  end
  return true
end

-- ─── MAIN ────────────────────────────────────────────────────────────────────

local function Main()
  if not init() then return end

  -- ── User parameters ───────────────────────────────────────────────────
  local ok, csv = reaper.GetUserInputs(SCRIPT_NAME, 2,
    "Target level (dBFS RMS)  e.g. -18 for -14 LUFS streaming:,"
    .. "True-peak ceiling (dBFS)  e.g. -0.3:",
    DEFAULT_TARGET .. "," .. PEAK_CEILING)
  if not ok then return end

  local parts      = parse_numbers(csv, 2)
  local target_db  = parts[1] or -18.0
  local ceiling_db = parts[2] or -0.3

  if target_db > 0 then
    reaper.MB(
      "Target level must be negative (e.g. −18 dBFS).\n"
      .. "A positive value would push peaks above 0 dBFS.",
      SCRIPT_NAME, 0)
    return
  end
  if ceiling_db > 0 then ceiling_db = -0.1 end


  -- ── Collect selected items ────────────────────────────────────────────
  local n_items = reaper.CountSelectedMediaItems(0)
  local items   = {}
  for i = 0, n_items - 1 do
    table.insert(items, reaper.GetSelectedMediaItem(0, i))
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local n_adjusted = 0
  local n_skipped  = 0
  local n_failed   = 0
  local log_lines  = {}

  for _, item in ipairs(items) do
    local take     = reaper.GetActiveTake(item)
    local src      = take and reaper.GetMediaItemTake_Source(take)
    local fname    = src  and (reaper.GetMediaSourceFileName(src, ""):match("[/\\]([^/\\]+)$") or "?")
                          or "?"

    local meas = measure_item(item)
    if not meas then
      n_failed = n_failed + 1
      table.insert(log_lines, ("SKIP  %-40s  (silent or unreadable)"):format(fname))
      goto continue
    end

    local delta_db = target_db - meas.rms_db

    if math.abs(delta_db) < SKIP_THRESHOLD then
      n_skipped = n_skipped + 1
      table.insert(log_lines,
        ("OK    %-40s  %.1f dBFS RMS  (already at target)"):format(fname, meas.rms_db))
      goto continue
    end

    -- Compute new linear gain, clamped so peaks stay below ceiling
    local current_vol = reaper.GetMediaItemInfo_Value(item, "D_VOL")
    local gain_factor = db_to_linear(delta_db)

    -- Estimated post-gain peak
    local est_peak_db = meas.peak_db + delta_db
    if est_peak_db > ceiling_db then
      -- Reduce gain so the peak lands exactly on the ceiling
      local overshoot = est_peak_db - ceiling_db
      delta_db    = delta_db - overshoot
      gain_factor = db_to_linear(delta_db)
      table.insert(log_lines,
        ("LIMIT %-40s  peak limited by %.1f dB"):format(fname, overshoot))
    end

    -- Keep the item volume positive; D_VOL is a linear gain (0 would mute).
    local new_vol = math.max(1e-6, current_vol * gain_factor)
    reaper.SetMediaItemInfo_Value(item, "D_VOL", new_vol)

    n_adjusted = n_adjusted + 1
    table.insert(log_lines,
      ("ADJ   %-40s  %+.1f dB  (%.1f → %.1f dBFS RMS, %s)")
      :format(fname, delta_db, meas.rms_db, meas.rms_db + delta_db,
              meas.method or "?"))

    ::continue::
  end

  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock(
    (SCRIPT_NAME .. " v" .. SCRIPT_VERSION .. ": %d items → %.0f dBFS RMS")
    :format(n_adjusted, target_db), -1)
  reaper.UpdateArrange()

  -- Log summary to console
  reaper.ShowConsoleMsg(("\n[%s] Results:\n"):format(SCRIPT_NAME))
  for _, line in ipairs(log_lines) do
    reaper.ShowConsoleMsg("  " .. line .. "\n")
  end

  reaper.MB(
    ("Normalisation complete!\n\n"
    .. "Adjusted : %d item(s)\n"
    .. "Skipped  : %d item(s)  (already at target ±%.1f dB)\n"
    .. "Failed   : %d item(s)  (silent / unreadable)\n\n"
    .. "Target   : %.1f dBFS RMS  (≈ %.0f LUFS)\n"
    .. "Ceiling  : %.1f dBFS peak\n\n"
    .. "Full log printed to REAPER Console (View > Show REAPER console).")
    :format(n_adjusted, n_skipped, SKIP_THRESHOLD, n_failed,
            target_db, target_db + 4,   -- rough LUFS = dBFS RMS + ~4 (K-weighted)
            ceiling_db),
    SCRIPT_NAME, 0)
end

Main()
