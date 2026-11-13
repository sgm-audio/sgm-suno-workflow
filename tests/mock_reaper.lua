--[[============================================================================
  mock_reaper.lua — A faithful offline mock of the ReaScript API.

  Purpose
  -------
  Run the SGM Suno Workflow scripts without REAPER, so behaviour can be
  asserted in CI. The mock deliberately reproduces the *documented* semantics
  of the functions the scripts use, including the parts that are easy to get
  wrong:

    * GetMediaItemTake_Peaks  — bit-packed return value (count in the low 20
      bits), two-block buffer layout (maximums block, then minimums block,
      interleaved per channel), and starttime expressed in PROJECT time.
    * GetAudioAccessorSamples — interleaved samples, project time.
    * SplitMediaItem          — returns the NEW right-hand item, keeps the
      original handle for the left part.
    * I_FOLDERDEPTH           — folder balance is validated by the tests.
    * Out-of-bounds reads on reaper.array set project.oob (asserted by tests).

  Signatures were taken from the official SDK header
  (justinfrankel/reaper-sdk: sdk/reaper_plugin_functions.h) and cross-checked
  against ReaTeam/ReaScripts usage.
============================================================================]]--

local M = {}

-- ─── forward decl ───────────────────────────────────────────────────────────
local new_array

-- ─── project model ──────────────────────────────────────────────────────────

function M.new_project()
  local P = {
    tracks      = {},
    markers     = {},
    tempo       = {},
    notes       = "",
    cursor      = 0,
    sel_s       = 0,
    sel_e       = 0,
    undo_depth  = 0,
    undo_blocks = {},
    console     = {},
    dialogs     = {},
    prompts     = {},   -- queue of csv strings; false = user cancelled
    file_dialog = nil,
    os_name     = "Linux-x86_64",
    app_version = "7.0/linux-x86_64",
    fs          = {},   -- path -> file contents (see io.open mock)
    dirs        = {},   -- path -> true
    popen       = {},   -- substring -> array of output lines
    zip_contents = {},  -- { {name=..., data=...}, ... } materialised on unzip
    shell       = {},   -- recorded os.execute() calls
    removed     = {},   -- paths passed to rmdir/rm -rf
    deferred    = {},
    oob         = false,
    imgui       = {
      buttons   = {},   -- queue of button labels that "click" themselves
      visible   = true,
      open      = false,
      text      = {},
    },
    temp_path   = "/tmp",
    env_vars    = { TEMP = "/tmp", TMPDIR = "/tmp" },
  }

  -- ── helpers exported on the project (used by tests) ──────────────────────

  function P:add_track(name, opts)
    opts = opts or {}
    local t = {
      name       = name or ("Track " .. (#self.tracks + 1)),
      color      = 0,
      selected   = opts.selected or false,
      folderdepth = opts.folderdepth or 0,
      items      = {},
      sends      = {},
    }
    self.tracks[#self.tracks + 1] = t
    return t
  end

  function P:add_source(filename, chans, samplerate, length, signal)
    local src = {
      filename   = filename,
      channels   = chans or 2,
      samplerate = samplerate or 44100,
      length     = length or 10.0,
      signal     = signal,          -- function(t) -> {amp_ch1, amp_ch2, ...}
      midi       = false,
    }
    self.sources = self.sources or {}
    self.sources[filename] = src
    return src
  end

  function P:add_item(track, src, pos, len, opts)
    opts = opts or {}
    local item = {
      pos    = pos or 0,
      len    = len or (src and src.length) or 1,
      vol    = opts.vol or 1.0,
      startoffs = opts.startoffs or 0,
      selected = opts.selected or false,
      track  = track,
    }
    item.take = {
      src  = src,
      name = opts.take_name or "",
      item = item,
    }
    track.items[#track.items + 1] = item
    return item
  end

  function P:tracks_named(name)
    local out = {}
    for _, t in ipairs(self.tracks) do
      if t.name == name then out[#out + 1] = t end
    end
    return out
  end

  function P:track_index(track)
    for i, t in ipairs(self.tracks) do if t == track then return i - 1 end end
    return -1
  end

  -- Sum of I_FOLDERDEPTH across all tracks must be 0 in a balanced project.
  function P:folder_balance()
    local sum = 0
    for _, t in ipairs(self.tracks) do sum = sum + (t.folderdepth or 0) end
    return sum
  end

  function P:console_text()
    return table.concat(self.console, "")
  end

  return P
end

-- ─── mock API ───────────────────────────────────────────────────────────────

-- `sources_by_path` lets PCM_Source_CreateFromFile resolve a filename to a
-- signal definition registered by the test.
function M.new_reaper(P)
  local R = {}
  P.sources = P.sources or {}

  -- ── signal helpers ───────────────────────────────────────────────────────
  local function src_of(take) return take and take.src or nil end

  -- Convert a project time to source-local time for a given item.
  local function project_to_source(item, t)
    return t - item.pos + (item.startoffs or 0)
  end

  -- Peak of a channel over [t0, t1) using sub-sampling.
  local function window_minmax(src, t0, t1, chan)
    if not src or not src.signal then return 0, 0 end
    local lo, hi = 0, 0
    local steps = 16
    for i = 0, steps do
      local t = t0 + (t1 - t0) * (i / steps)
      local v = src.signal(t)
      local a = v and v[chan]
      if a then
        if a > hi then hi = a end
        if a < lo then lo = a end
      end
    end
    return hi, lo
  end

  -- ── project / track counts ───────────────────────────────────────────────
  function R.CountTracks() return #P.tracks end
  function R.GetTrack(_, idx) return P.tracks[idx + 1] end
  function R.GetNumTracks() return #P.tracks end

  function R.InsertTrackAtIndex(idx, _want)
    local t = { name = "", color = 0, selected = false, folderdepth = 0,
                items = {}, sends = {} }
    table.insert(P.tracks, idx + 1, t)
    return true
  end

  function R.GetMediaTrackInfo_Value(track, key)
    if key == "I_FOLDERDEPTH" then return track.folderdepth or 0 end
    if key == "IP_TRACKNUMBER" then
      local i = P:track_index(track)
      return i >= 0 and (i + 1) or -1
    end
    if key == "I_SELECTED" then return track.selected and 1 or 0 end
    if key == "B_MUTE" then return 0 end
    return 0
  end

  function R.SetMediaTrackInfo_Value(track, key, val)
    if key == "I_FOLDERDEPTH" then track.folderdepth = val
    elseif key == "B_MUTE" then track.mute = val ~= 0
    end
    return true
  end

  function R.GetSetMediaTrackInfo_String(track, key, val, set)
    if key == "P_NAME" then
      if set then track.name = val end
      return true, track.name
    end
    return false, ""
  end

  function R.SetTrackColor(track, color) track.color = color end
  function R.GetTrackColor(track) return track.color end
  function R.IsTrackSelected(track) return track.selected and true or false end
  function R.SetTrackSelected(track, sel) track.selected = sel and true or false end
  function R.SetOnlyTrackSelected(track)
    for _, t in ipairs(P.tracks) do t.selected = (t == track) end
  end

  -- ── items / takes ────────────────────────────────────────────────────────
  local function all_items()
    local out = {}
    for _, t in ipairs(P.tracks) do
      for _, it in ipairs(t.items) do out[#out + 1] = it end
    end
    return out
  end
  P.all_items = all_items

  function R.CountTrackMediaItems(track) return #track.items end
  function R.GetTrackMediaItem(track, i) return track.items[i + 1] end

  function R.CountSelectedMediaItems()
    local n = 0
    for _, it in ipairs(all_items()) do if it.selected then n = n + 1 end end
    return n
  end

  function R.GetSelectedMediaItem(_, i)
    local n = 0
    for _, it in ipairs(all_items()) do
      if it.selected then
        if n == i then return it end
        n = n + 1
      end
    end
    return nil
  end

  function R.GetMediaItemInfo_Value(item, key)
    if key == "D_POSITION"  then return item.pos end
    if key == "D_LENGTH"    then return item.len end
    if key == "D_VOL"       then return item.vol end
    if key == "D_STARTOFFS" then return item.startoffs end
    if key == "B_MUTE"      then return item.mute or 0 end
    return 0
  end

  function R.SetMediaItemInfo_Value(item, key, val)
    if key == "D_POSITION"  then item.pos = val
    elseif key == "D_LENGTH"    then item.len = val
    elseif key == "D_VOL"       then item.vol = val
    elseif key == "D_STARTOFFS" then item.startoffs = val
    elseif key == "D_SNAPOFFSET" then item.snapoffset = val
    elseif key == "B_MUTE"      then item.mute = val
    end
    return true
  end

  function R.SetMediaItemSelected(item, sel) item.selected = sel and true or false end
  function R.GetActiveTake(item) return item and item.take or nil end
  function R.TakeIsMIDI(take) return (take and take.src and take.src.midi) and true or false end
  function R.GetMediaItemTake_Source(take) return src_of(take) end
  function R.SetMediaItemTake_Source(take, src) take.src = src; return true end
  function R.UpdateItemInProject() return true end
  function R.AddMediaItemToTrack(track) return P:add_item(track, nil, 0, 1) end
  function R.AddTakeToMediaItem(item)
    item.take = item.take or { name = "", item = item }
    return item.take
  end

  function R.GetSetMediaItemTakeInfo_String(take, key, val, set)
    if key == "P_NAME" then
      if set then take.name = val end
      return true, take.name or ""
    end
    return false, ""
  end

  -- SplitMediaItem: returns the NEW item to the right; the original handle
  -- keeps the left portion.
  function R.SplitMediaItem(item, pos)
    if pos <= item.pos + 1e-9 or pos >= item.pos + item.len - 1e-9 then
      return nil
    end
    local track = item.track
    local idx
    for i, it in ipairs(track.items) do if it == item then idx = i end end
    local right = {
      pos = pos,
      len = item.pos + item.len - pos,
      vol = item.vol,
      startoffs = (item.startoffs or 0) + (pos - item.pos),
      selected = item.selected,
      track = track,
      take = { src = item.take.src, name = item.take.name, item = nil },
    }
    right.take.item = right
    item.len = pos - item.pos
    table.insert(track.items, idx + 1, right)
    return right
  end

  function R.PCM_Source_CreateFromFile(path)
    local src = P.sources[path]
    if not src then return nil end
    return src
  end

  function R.GetMediaSourceLength(src) return src and src.length or 0 end
  function R.GetMediaSourceNumChannels(src) return src and src.channels or 0 end
  function R.GetMediaSourceSampleRate(src) return src and src.samplerate or 0 end
  function R.GetMediaSourceFileName(src) return src and src.filename or "" end

  -- ── peaks (official semantics) ───────────────────────────────────────────
  -- count = retval & 0xFFFFF ; buffer = [maximums: ns*chans] [minimums: ns*chans]
  -- interleaved per channel within each block; starttime is PROJECT time.
  function R.GetMediaItemTake_Peaks(take, peakrate, starttime, numchans, numsamples, _extra, buf)
    local src = src_of(take)
    if not src or not src.signal or not take.item then return 0 end
    local item = take.item
    local chan_count = math.min(numchans, src.channels)
    local min_off = numchans * numsamples
    local returned = 0
    for s = 1, numsamples do
      local t0 = starttime + (s - 1) / peakrate
      local t1 = t0 + 1 / peakrate
      local written = false
      for c = 1, chan_count do
        local st0 = project_to_source(item, t0)
        local st1 = project_to_source(item, t1)
        local hi, lo = window_minmax(src, st0, st1, c)
        local base = (s - 1) * numchans + (c - 1)
        buf[base + 1]     = hi
        buf[min_off + base + 1] = lo
        written = true
      end
      if written then returned = returned + 1 end
    end
    -- output_mode 0 in bits 20-23; no extra_type requested.
    return returned & 0xFFFFF
  end

  -- ── audio accessor ───────────────────────────────────────────────────────
  function R.CreateTakeAudioAccessor(take)
    local item = take and take.item
    if not item then return nil end
    return { take = take, item = item }
  end
  function R.DestroyAudioAccessor() return true end
  function R.AudioAccessorStateChanged() return false end
  function R.AudioAccessorValidateState() return true end
  function R.GetAudioAccessorStartTime(acc) return acc.item.pos end
  function R.GetAudioAccessorEndTime(acc) return acc.item.pos + acc.item.len end

  function R.GetAudioAccessorSamples(acc, samplerate, numchans, starttime, numsamples, buf)
    local src = src_of(acc.take)
    if not src or not src.signal then return 0 end
    local chans = math.min(numchans, src.channels)
    local item = acc.item
    local any = false
    for s = 1, numsamples do
      local t = project_to_source(item, starttime + (s - 1) / samplerate)
      local v = src.signal(t)
      for c = 1, numchans do
        local a = (c <= chans and v and v[c]) or 0
        buf[(s - 1) * numchans + c] = a
        if a ~= 0 then any = true end
      end
    end
    return any and 1 or 0
  end

  -- ── markers / regions ────────────────────────────────────────────────────
  function R.AddProjectMarker2(_, isrgn, pos, rgnend, name, wantidx, color)
    P.marker_id = (P.marker_id or 0) + 1
    table.insert(P.markers, {
      isrgn = isrgn, pos = pos, endpos = rgnend, name = name,
      idx = wantidx, color = color, id = P.marker_id,
    })
    return P.marker_id
  end

  function R.CountProjectMarkers()
    return #P.markers, #P.markers
  end

  -- ── tempo ────────────────────────────────────────────────────────────────
  function R.AddTempoTimeSigMarker(_, timepos, bpm, num, den, linear)
    table.insert(P.tempo, { pos = timepos, bpm = bpm, num = num, den = den,
                            linear = linear and true or false })
    table.sort(P.tempo, function(a, b) return a.pos < b.pos end)
    return true
  end

  function R.SetTempoTimeSigMarker(_, ptidx, timepos, _mp, _bp, bpm, num, den, linear)
    if ptidx < 0 then
      return R.AddTempoTimeSigMarker(0, timepos, bpm, num, den, linear)
    end
    local m = P.tempo[ptidx + 1]
    if not m then return false end
    m.pos, m.bpm, m.num, m.den = timepos, bpm, num, den
    return true
  end

  function R.CountTempoTimeSigMarkers() return #P.tempo end

  function R.GetTempoTimeSigMarker(_, idx)
    local m = P.tempo[idx + 1]
    if not m then return false end
    return true, m.pos, -1, -1, m.bpm, m.num, m.den, m.linear and true or false
  end

  function R.DeleteTempoTimeSigMarker(_, idx)
    if not P.tempo[idx + 1] then return false end
    table.remove(P.tempo, idx + 1)
    return true
  end

  function R.GetProjectTimeSignature2() return 120.0, 4 end

  -- ── edit state ───────────────────────────────────────────────────────────
  function R.GetCursorPosition() return P.cursor end
  function R.SetEditCurPos(pos) P.cursor = pos end

  function R.GetSet_LoopTimeRange(isSet, _isLoop, s, e)
    local a, b = P.sel_s, P.sel_e
    if isSet then P.sel_s, P.sel_e = s, e end
    return a, b
  end

  -- ── misc ─────────────────────────────────────────────────────────────────
  function R.ColorToNative(r, g, b)
    return (r << 16) | (g << 8) | b
  end

  function R.GetSetProjectNotes(_, set, notes)
    if set then P.notes = notes; return true end
    return P.notes
  end

  function R.Undo_BeginBlock()
    P.undo_depth = P.undo_depth + 1
    if P.undo_depth > 1 then P.undo_unbalanced = true end
    return true
  end

  function R.Undo_EndBlock(name)
    P.undo_depth = P.undo_depth - 1
    if P.undo_depth < 0 then P.undo_unbalanced = true end
    table.insert(P.undo_blocks, name)
    return true
  end

  function R.Undo_OnStateChange(name) return R.Undo_EndBlock(name) end
  function R.PreventUIRefresh(n) P.ui_refresh = (P.ui_refresh or 0) + n end
  function R.UpdateArrange() P.arrange_updates = (P.arrange_updates or 0) + 1 end
  function R.UpdateTimeline() return true end
  function R.TrackList_AdjustWindows() return true end
  function R.Main_OnCommand(cmd) table.insert(P.commands or {}, cmd); return true end
  function R.MarkProjectDirty() return true end

  function R.ShowConsoleMsg(msg) table.insert(P.console, msg) end

  function R.MB(msg, title, _type)
    table.insert(P.dialogs, { msg = msg, title = title })
    return 0
  end

  function R.GetOS() return P.os_name end
  function R.GetAppVersion() return P.app_version end

  function R.GetUserInputs(title, nfields, _captions, defaults)
    local next_prompt = table.remove(P.prompts, 1)
    if next_prompt == nil then
      -- No scripted answer left: cancel so the script exits cleanly.
      return false, ""
    end
    if next_prompt == false then return false, "" end
    -- "@default" = the user presses OK without editing anything.
    if next_prompt == "@default" then return true, defaults end
    -- Pad / truncate to nfields so field-index bugs surface.
    local parts = {}
    for p in tostring(next_prompt):gmatch("([^,]*),?") do parts[#parts + 1] = p end
    if parts[#parts] == "" then parts[#parts] = nil end
    while #parts < nfields do parts[#parts + 1] = "" end
    return true, table.concat(parts, ",", 1, nfields)
  end

  function R.GetUserFileNameForRead(_f, _title, _ext)
    if P.file_dialog then return true, P.file_dialog end
    return false, ""
  end

  function R.new_array(size) return new_array(P, size) end

  function R.defer(fn) table.insert(P.deferred, fn) end
  function R.atexit(fn) table.insert(P.deferred, fn) end

  -- ── track sends ──────────────────────────────────────────────────────────
  local next_send_id = 0
  function R.CreateTrackSend(src, dest)
    if not src or not dest then return -1 end
    next_send_id = next_send_id + 1
    table.insert(src.sends, { dest = dest, mode = 0, id = next_send_id })
    return #src.sends - 1
  end

  function R.SetTrackSendInfo_Value(track, cat, idx, parm, val)
    local s = track.sends and track.sends[idx + 1]
    if not s then return false end
    if parm == "I_SENDMODE" then s.mode = val end
    return true
  end

  function R.GetTrackNumSends(track, cat) return #(track.sends or {}) end
  function R.RemoveTrackSend() return true end

  return R
end

-- ─── reaper.array mock ──────────────────────────────────────────────────────

new_array = function(P, size)
  local data = {}
  local methods = {
    clear = function()
      for i = 1, size do data[i] = 0 end
    end,
    table = function()
      local c = {}
      for i = 1, size do c[i] = data[i] or 0 end
      return c
    end,
    resize = function(n) size = n end,
  }
  local mt = {
    __index = function(_, k)
      if type(k) == "string" then return methods[k] end
      if k < 1 or k > size then
        P.oob = true          -- tests assert this never happens
        return 0
      end
      return data[k] or 0
    end,
    __newindex = function(_, k, v)
      if type(k) == "number" then
        if k < 1 or k > size then
          P.oob = true
          return
        end
        data[k] = v
      end
    end,
    __len = function() return size end,
  }
  return setmetatable({}, mt)
end

-- ─── ImGui mock ─────────────────────────────────────────────────────────────

-- Returns a table of stubs for every reaper.ImGui_* name the scripts use.
-- Buttons listed in P.imgui.buttons "click themselves" in order.
function M.new_imgui(P)
  local I = {}
  I.__module = "imgui"

  local function noop() return nil end

  local function btn(ctx, label)
    local queue = P.imgui.buttons
    -- ImGui labels are compared with surrounding padding trimmed, so a test can
    -- click "Import" without repeating the button's layout spaces.
    local function norm(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
    if queue[1] and norm(queue[1]) == norm(label) then
      table.remove(queue, 1)
      return true
    end
    return false
  end

  local defaults = {
    ImGui_CreateContext          = function() return { ctx = true } end,
    ImGui_DestroyContext         = noop,
    ImGui_Begin                  = function() return P.imgui.visible, P.imgui.open end,
    ImGui_End                    = noop,
    ImGui_SetNextWindowSize      = noop,
    ImGui_SetNextWindowPos       = noop,
    ImGui_SetNextItemWidth       = noop,
    ImGui_Text                   = function(_, s) table.insert(P.imgui.text, s) end,
    ImGui_TextColored            = function(_, _, s) table.insert(P.imgui.text, s) end,
    ImGui_TextWrapped            = function(_, s) table.insert(P.imgui.text, s) end,
    ImGui_Separator              = noop,
    ImGui_Spacing                = noop,
    ImGui_SameLine               = noop,
    ImGui_Button                 = btn,
    ImGui_BeginDisabled          = noop,
    ImGui_EndDisabled            = noop,
    ImGui_InputText              = function(_, _, buf) return false, buf end,
    ImGui_ProgressBar            = noop,
    ImGui_BeginChild             = function() return true end,
    ImGui_EndChild               = noop,
    ImGui_GetContentRegionAvail  = function() return 600, 400 end,
    ImGui_GetScrollY             = function() return 0 end,
    ImGui_GetScrollMaxY          = function() return 0 end,
    ImGui_SetScrollHereY         = noop,
    ImGui_PushStyleColor         = noop,
    ImGui_PopStyleColor          = noop,
    ImGui_GetContentRegionAvail  = function() return 600, 400 end,
    -- NOTE: this ReaImGui helper takes no context argument.
    ImGui_ColorConvertDouble4ToU32 = function(r, g, b, a)
      local function byte(v) return math.floor((v or 1) * 255 + 0.5) & 0xFF end
      return (byte(a) << 24) | (byte(b) << 16) | (byte(g) << 8) | byte(r)
    end,
  }

  -- Flag enums, exposed as functions in ReaImGui >= 0.9.
  local flags = {
    "WindowFlags_NoCollapse", "WindowFlags_NoResize", "WindowFlags_AlwaysAutoResize",
    "InputTextFlags_ReadOnly", "Cond_Once", "Cond_Always", "Col_Text",
  }
  for _, f in ipairs(flags) do
    defaults["ImGui_" .. f] = function() return 1 end
  end

  setmetatable(I, {
    __index = function(_, k)
      if defaults[k] then return function(...) return defaults[k](...) end end
      -- Any other ImGui_* call is a harmless no-op returning nil.
      return function() return nil end
    end,
  })
  return I
end

-- ─── sandbox environment ────────────────────────────────────────────────────

-- Builds the _ENV handed to a script: mock reaper (+ ImGui), plus a fake
-- os / io / lfs so filesystem and shell paths are hermetic.
function M.new_env(P)
  local R = M.new_reaper(P)
  local I = M.new_imgui(P)

  local env = {}
  env._G = env

  -- reaper with ImGui namespaces merged in
  local reaper = setmetatable({}, {
    __index = function(_, k)
      if R[k] ~= nil then return R[k] end
      -- ReaImGui lives in the same namespace but is an extension, so only
      -- consult it for ImGui_* names (and only when the extension is enabled).
      if not P.no_imgui and k:sub(1, 6) == "ImGui_" then return I[k] end
      -- Unknown API: return nil so calling it fails loudly, exactly like a
      -- missing REAPER version / extension would at runtime.
      return nil
    end,
  })
  env.reaper = reaper

  -- ── file system ──────────────────────────────────────────────────────────
  local fs = P.fs
  local File = {}
  File.__index = File
  function File:read(fmt)
    if fmt == "*a" or fmt == "a" then
      local s = self.content
      self.pos = #s + 1
      return s
    end
    if fmt == "*l" or fmt == "l" then
      local s = self.content
      if self.pos > #s then return nil end
      local nl = s:find("\n", self.pos, true)
      local line
      if nl then
        line = s:sub(self.pos, nl - 1)
        self.pos = nl + 1
      else
        line = s:sub(self.pos)
        self.pos = #s + 1
      end
      return line
    end
    return nil
  end
  function File:lines()
    return function()
      return self:read("l")
    end
  end
  function File:close() self.closed = true; return true end

  env.io = {
    open = function(path, mode)
      local content = fs[path]
      if mode and mode:find("w") then
        fs[path] = ""
        return setmetatable({ content = "", pos = 1, path = path }, File)
      end
      if content == nil then return nil end
      return setmetatable({ content = content, pos = 1, path = path }, File)
    end,
    popen = function(cmd)
      table.insert(P.shell or {}, cmd)
      local out
      for key, lines in pairs(P.popen) do
        if cmd:find(key, 1, true) then out = lines break end
      end
      if out == nil then return nil end
      local i = 0
      return {
        lines = function()
          return function()
            i = i + 1
            return out[i]
          end
        end,
        close = function() return true end,
      }
    end,
    write = function() return true end,
  }

  env.os = {
    time = function() return 1700000000 end,
    getenv = function(k) return P.env_vars[k] end,
    execute = function(cmd)
      table.insert(P.shell, cmd)
      if cmd:find("rmdir", 1, true) or cmd:find("rm -rf", 1, true) then
        table.insert(P.removed, cmd)
        return 0
      end
      -- Simulate `unzip -o "x.zip" -d "DIR"` (either quote style):
      -- materialise P.zip_contents into DIR.
      local dir = cmd:match('%-d%s*"([^"]+)"') or cmd:match("%-d%s*'([^']+)'")
      if dir and cmd:find("unzip", 1, true) then
        for _, member in ipairs(P.zip_contents or {}) do
          fs[dir .. "/" .. member.name] = member.data or ""
        end
        P.dirs[dir] = true
      end
      return 0
    end,
    remove = function(p) table.insert(P.removed, p); return true end,
    tmpname = function() return "/tmp/lua_tmp" end,
    date = function() return "2026-01-01" end,
  }

  -- lfs: a tiny in-memory implementation driven by P.dirs / P.fs
  local lfs = {}
  function lfs.attributes(path)
    if fs[path] ~= nil then return { mode = "file" } end
    if P.dirs[path] then return { mode = "directory" } end
    return nil
  end
  function lfs.mkdir(path)
    P.dirs[path] = true
    return true
  end
  function lfs.dir(path)
    -- Build the child list from registered dirs and files.
    local prefix = path:sub(-1) == "/" and path or (path .. "/")
    local children = {}
    local seen = {}
    for p in pairs(fs) do
      if p:sub(1, #prefix) == prefix then
        local rest = p:sub(#prefix + 1)
        local name = rest:match("^([^/]+)") or rest
        if not seen[name] then seen[name] = true; children[#children + 1] = name end
      end
    end
    for p in pairs(P.dirs) do
      if p ~= path and p:sub(1, #prefix) == prefix then
        local rest = p:sub(#prefix + 1)
        local name = rest:match("^([^/]+)") or rest
        if name ~= "" and not seen[name] then
          seen[name] = true
          children[#children + 1] = name
        end
      end
    end
    local i = 0
    local list = { ".", ".." }
    for _, c in ipairs(children) do list[#list + 1] = c end
    return function()
      i = i + 1
      return list[i]
    end
  end
  env.lfs = lfs

  -- Lua stdlib the scripts rely on
  env.string, env.table, env.math, env.tostring, env.tonumber = string, table, math, tostring, tonumber
  env.pairs, env.ipairs, env.type, env.select, env.error = pairs, ipairs, type, select, error
  env.assert, env.pcall, env.print = assert, pcall, print
  env.setmetatable, env.getmetatable, env.rawget = setmetatable, getmetatable, rawget
  env.os_time = os.time

  return env
end

return M
