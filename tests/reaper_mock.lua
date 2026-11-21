-- @license MIT (c) 2026 Scott Mills / SGM Studios
-- In-memory stand-in for REAPER's ReaScript API for sgm-suno-workflow.

local mock = {}

local function new_item(opts)
  opts = opts or {}
  local it = {
    position = opts.position or 0.0,
    length = opts.length or 10.0,
    vol = opts.vol or 1.0,
    fadein = opts.fadein or 0.0,
    fadeout = opts.fadeout or 0.0,
    mute = opts.mute or 0,
    takes = {},
    track = opts.track,
  }
  local tk = {
    item = it,
    name = opts.take_name or "Take 1",
    is_midi = opts.is_midi or false,
    peaks = opts.peaks or nil,
    source = {
      filename = opts.filename or "audio.wav",
      channels = opts.channels or 2,
      samplerate = opts.samplerate or 44100,
      length = opts.length or 10.0,
    }
  }
  it.takes[1] = tk
  return it
end

local function new_track(name)
  return {
    name = name or "",
    fx = {},
    sends = {},
    mainsend = 1,
    folderdepth = 0,
    vol = 1.0,
    pan = 0.0,
    color = nil,
    items = {},
  }
end

function mock.new()
  local r = {
    _tracks = {},
    _selected_tracks = {},
    _selected_items = {},
    _messages = {},
    _markers = {},
    _tempo_markers = {},
    _ui_refresh = 0,
    _undo_depth = 0,
    _undo_begin_count = 0,
    _undo_end_count = 0,
    _user_inputs = {},      -- queue of return strings
    _user_input_default = "0.35,4,4,0",
    _mb_answer = 1,        -- 1 = OK
    _mb_prompts = {},
    _cursor_pos = 0.0,
    _loop_start = 0.0,
    _loop_end = 0.0,
    _project_notes = "",
  }

  -- Console
  function r.ShowConsoleMsg(s) r._messages[#r._messages + 1] = tostring(s) end
  function r.ClearConsole() r._messages = {} end
  function r.GetOS() return "Linux" end
  function r.GetAppVersion() return "7.83/linux" end
  function r.time_precise() return 1.0 end
  function r.defer(_f) end
  function r.UpdateArrange() end
  function r.TrackList_AdjustWindows() end
  function r.UpdateTimeline() end
  function r.UpdateItemInProject(_item) end
  function r.Main_OnCommand(_cmd, _flag) end

  -- Dialogs
  function r.MB(text, title, mtype)
    r._mb_prompts[#r._mb_prompts + 1] = { title = title, text = tostring(text), type = mtype }
    return r._mb_answer
  end

  function r.GetUserInputs(_title, _num_inputs, _captions_csv, retvals_csv)
    local val = r._user_inputs[1]
    if val ~= nil then
      table.remove(r._user_inputs, 1)
      if val == false then return false, "" end
      return true, val
    end
    if r._user_input_default == false then return false, "" end
    return true, r._user_input_default or retvals_csv
  end

  -- Undo & UI
  function r.Undo_BeginBlock()
    r._undo_begin_count = r._undo_begin_count + 1
    r._undo_depth = r._undo_depth + 1
  end
  function r.Undo_EndBlock(_desc, _extraflags)
    r._undo_end_count = r._undo_end_count + 1
    r._undo_depth = r._undo_depth - 1
  end
  function r.PreventUIRefresh(n)
    r._ui_refresh = r._ui_refresh + n
  end

  -- Cursor & Time
  function r.GetCursorPosition() return r._cursor_pos end
  function r.SetEditCurPos(pos, _moveview, _seekplay) r._cursor_pos = pos end
  function r.GetSet_LoopTimeRange(isSet, _isLoop, start_t, end_t, _allowautoseek)
    if isSet then
      r._loop_start = start_t
      r._loop_end = end_t
    end
    return r._loop_start, r._loop_end
  end

  -- Colors
  function r.ColorToNative(rr, gg, bb)
    return rr * 65536 + gg * 256 + bb
  end

  -- Tracks
  function r.CountTracks() return #r._tracks end
  function r.GetTrack(_proj, i) return r._tracks[i + 1] end
  function r.InsertTrackAtIndex(idx, _wantDefaults)
    local t = new_track("")
    table.insert(r._tracks, idx + 1, t)
    return t
  end
  function r.SetOnlyTrackSelected(tr)
    r._selected_tracks = { tr }
  end
  function r.IsTrackSelected(tr)
    for _, t in ipairs(r._selected_tracks) do
      if t == tr then return true end
    end
    return false
  end
  function r.GetSetMediaTrackInfo_String(tr, parmname, val, setNew)
    if not tr then return false, "" end
    if parmname == "P_NAME" then
      if setNew then tr.name = val end
      return true, tr.name
    end
    return false, ""
  end
  function r.SetTrackColor(tr, col)
    if tr then tr.color = col end
  end
  function r.GetMediaTrackInfo_Value(tr, key)
    if not tr then return 0 end
    if key == "I_FOLDERDEPTH" then return tr.folderdepth or 0
    elseif key == "B_MAINSEND" then return tr.mainsend or 1
    elseif key == "IP_TRACKNUMBER" then
      for i, t in ipairs(r._tracks) do
        if t == tr then return i end
      end
      return -1
    end
    return 0
  end
  function r.SetMediaTrackInfo_Value(tr, key, val)
    if not tr then return false end
    if key == "I_FOLDERDEPTH" then tr.folderdepth = val
    elseif key == "B_MAINSEND" then tr.mainsend = val
    end
    return true
  end

  -- Track items
  function r.CountTrackMediaItems(tr)
    if not tr then return 0 end
    return #tr.items
  end
  function r.GetTrackMediaItem(tr, idx)
    if not tr then return nil end
    return tr.items[idx + 1]
  end

  -- Selected items
  function r.CountSelectedMediaItems()
    return #r._selected_items
  end
  function r.GetSelectedMediaItem(_proj, idx)
    return r._selected_items[idx + 1]
  end

  -- Media items
  function r.GetMediaItemInfo_Value(it, key)
    if not it then return 0 end
    if key == "D_POSITION" then return it.position or 0
    elseif key == "D_LENGTH" then return it.length or 0
    elseif key == "D_VOL" then return it.vol or 1.0
    elseif key == "B_MUTE" then return it.mute or 0
    elseif key == "D_FADEINLEN" then return it.fadein or 0
    elseif key == "D_FADEOUTLEN" then return it.fadeout or 0
    end
    return 0
  end
  function r.SetMediaItemInfo_Value(it, key, val)
    if not it then return false end
    if key == "D_POSITION" then it.position = val
    elseif key == "D_LENGTH" then it.length = val
    elseif key == "D_VOL" then it.vol = val
    elseif key == "B_MUTE" then it.mute = val
    elseif key == "D_FADEINLEN" then it.fadein = val
    elseif key == "D_FADEOUTLEN" then it.fadeout = val
    end
    return true
  end

  -- Takes
  function r.GetActiveTake(it)
    if not it or not it.takes then return nil end
    return it.takes[1]
  end
  function r.TakeIsMIDI(tk)
    return tk and tk.is_midi or false
  end
  function r.GetMediaItemTake_Source(tk)
    if not tk then return nil end
    return tk.source
  end
  function r.GetSetMediaItemTakeInfo_String(tk, parmname, val, setNew)
    if not tk then return false, "" end
    if parmname == "P_NAME" then
      if setNew then tk.name = val end
      return true, tk.name
    end
    return false, ""
  end

  -- Sources
  function r.GetMediaSourceParent(src)
    return src and src.parent or nil
  end
  function r.GetMediaSourceFileName(src, _buf)
    return src and src.filename or ""
  end
  function r.GetMediaSourceNumChannels(src)
    return src and src.channels or 2
  end
  function r.GetMediaSourceLength(src)
    return src and src.length or 10.0, false
  end

  -- Peaks
  function r.new_array(n)
    local arr = { _size = n }
    for i = 1, n do arr[i] = 0.0 end
    return setmetatable(arr, {
      __len = function() return n end
    })
  end

  function r.GetMediaItemTake_Peaks(tk, peakrate, starttime, num_chans, n_req, _want_extra_type, buf)
    if not tk then return 0 end
    local item_pos = tk.item and tk.item.position or 0.0
    local item_len = tk.item and tk.item.length or 10.0
    if starttime < item_pos - 1e-6 or starttime >= item_pos + item_len then
      return 0
    end
    local n = math.min(n_req, math.ceil((item_pos + item_len - starttime) * peakrate))
    if n <= 0 then return 0 end
    local offset_samples = math.floor((starttime - item_pos) * peakrate + 0.5)
    for s = 1, n do
      local val
      if tk.peaks then
        val = tk.peaks[offset_samples + s] or 0.25
      else
        local t = (offset_samples + s - 1) / peakrate
        local pulse = math.abs(math.sin(t * math.pi * 2.0))
        val = 0.1 + 0.6 * (pulse ^ 8)
      end
      for c = 0, num_chans - 1 do
        buf[(s - 1) * num_chans + c + 1] = val
        buf[n * num_chans + (s - 1) * num_chans + c + 1] = -val
      end
    end
    return n
  end

  -- Split Item
  function r.SplitMediaItem(item, pos)
    if not item then return nil end
    local start = item.position
    local len = item.length
    if pos <= start or pos >= start + len then return nil end
    local left_len = pos - start
    local right_len = len - left_len
    item.length = left_len

    local right_item = new_item({
      position = pos,
      length = right_len,
      vol = item.vol,
      track = item.track,
      filename = item.takes[1] and item.takes[1].source and item.takes[1].source.filename,
    })
    if item.takes[1] then
      right_item.takes[1].name = item.takes[1].name
      right_item.takes[1].peaks = item.takes[1].peaks
    end
    if item.track then
      table.insert(item.track.items, right_item)
    end
    return right_item
  end

  -- Markers & Regions
  function r.AddProjectMarker2(_proj, isrgn, pos, rgnend, name, _wantidx, color)
    local idx = #r._markers + 1
    r._markers[idx] = {
      isrgn = isrgn,
      pos = pos,
      rgnend = rgnend,
      name = name,
      color = color,
    }
    return idx
  end

  -- Tempo markers
  function r.CountTempoTimeSigMarkers(_proj)
    return #r._tempo_markers
  end
  function r.GetTempoTimeSigMarker(_proj, idx)
    local m = r._tempo_markers[idx + 1]
    if not m then return false end
    return true, m.pos, 0, 0.0, m.bpm, m.ts_num, m.ts_den, m.linear
  end
  function r.DeleteTempoTimeSigMarker(_proj, idx)
    if idx < 0 or idx >= #r._tempo_markers then return false end
    table.remove(r._tempo_markers, idx + 1)
    return true
  end
  function r.SetTempoTimeSigMarker(_proj, idx, pos, _measurepos, _beatpos, bpm, ts_num, ts_den, linear)
    if idx == -1 then
      table.insert(r._tempo_markers, {
        pos = pos,
        bpm = bpm,
        ts_num = ts_num,
        ts_den = ts_den,
        linear = linear,
      })
      return true
    end
    local m = r._tempo_markers[idx + 1]
    if not m then return false end
    m.pos = pos
    m.bpm = bpm
    m.ts_num = ts_num
    m.ts_den = ts_den
    m.linear = linear
    return true
  end
  function r.AddTempoTimeSigMarker(_proj, pos, bpm, ts_num, ts_den, linear)
    local m = {
      pos = pos,
      bpm = bpm,
      ts_num = ts_num,
      ts_den = ts_den,
      linear = linear,
    }
    table.insert(r._tempo_markers, m)
    return #r._tempo_markers - 1
  end

  -- Routing
  function r.CreateTrackSend(src, dst)
    if not src or not dst then return -1 end
    local send = {
      dest = dst,
      D_VOL = 1.0,
      D_PAN = 0.0,
      I_SENDMODE = 0,
    }
    src.sends[#src.sends + 1] = send
    return #src.sends - 1
  end
  function r.SetTrackSendInfo_Value(tr, _cat, idx, key, val)
    if not tr or not tr.sends[idx + 1] then return false end
    tr.sends[idx + 1][key] = val
    return true
  end

  -- Project Notes
  function r.GetSetProjectNotes(_proj, set, notes)
    if set then r._project_notes = notes end
    return r._project_notes
  end

  -- Paths & Filesystem (for ZIP Importer tests)
  r._project_path = ""
  r._resource_path = ""
  function r.GetProjectPath() return r._project_path end
  function r.GetResourcePath() return r._resource_path end
  function r.CF_GetSWSVersion() return "2.14.0" end
  function r.file_exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
  end
  function r.RecursiveCreateDirectory(path, _ignored)
    os.execute('mkdir -p "' .. tostring(path):gsub('"', '\\"') .. '"')
    return 1
  end
  function r.EnumerateFiles(dir, idx)
    local p = io.popen('ls -1p "' .. tostring(dir):gsub('"', '\\"') .. '" 2>/dev/null | grep -v /')
    if not p then return nil end
    local i = 0
    local found = nil
    for line in p:lines() do
      if i == idx then found = line; break end
      i = i + 1
    end
    p:close()
    return found
  end
  function r.EnumerateSubdirectories(dir, idx)
    local p = io.popen('ls -1p "' .. tostring(dir):gsub('"', '\\"') .. '" 2>/dev/null | grep /')
    if not p then return nil end
    local i = 0
    local found = nil
    for line in p:lines() do
      if i == idx then found = line:gsub("/$", ""); break end
      i = i + 1
    end
    p:close()
    return found
  end

  -- Media creation (for ZIP Importer tests)
  function r.PCM_Source_CreateFromFile(filepath)
    if not r.file_exists(filepath) then return nil end
    return { filename = filepath, channels = 2, samplerate = 44100, length = 12.0 }
  end
  function r.AddMediaItemToTrack(tr)
    if not tr then return nil end
    local it = {
      position = 0.0,
      length = 0.0,
      vol = 1.0,
      fadein = 0.0,
      fadeout = 0.0,
      mute = 0,
      takes = {},
      track = tr,
    }
    tr.items[#tr.items + 1] = it
    return it
  end
  function r.AddTakeToMediaItem(it)
    if not it then return nil end
    local tk = { item = it, name = "", is_midi = false, source = nil }
    it.takes[#it.takes + 1] = tk
    return tk
  end
  function r.SetMediaItemTake_Source(tk, src)
    if not tk then return false end
    tk.source = src
    return true
  end
  function r.DeleteTrackMediaItem(tr, it)
    if not tr or not it then return false end
    for i, v in ipairs(tr.items) do
      if v == it then table.remove(tr.items, i); return true end
    end
    return false
  end

  -- Minimal ReaImGui stubs for headless testing
  r._imgui_browse_path = ""
  r._imgui_trigger_browse = false
  r._imgui_trigger_import = false
  r._imgui_open = false
  function r.ImGui_CreateContext(_name) return { _ctx = true } end
  function r.ImGui_ColorConvertDouble4ToU32(_r, _g, _b, _a) return 0xFFFFFFFF end
  function r.ImGui_WindowFlags_NoCollapse() return 1 end
  function r.ImGui_WindowFlags_NoResize() return 2 end
  function r.ImGui_Cond_Once() return 1 end
  function r.ImGui_InputTextFlags_ReadOnly() return 1 end
  function r.ImGui_Col_Text() return 0 end
  function r.ImGui_SetNextWindowSize(_ctx, _w, _h, _cond) end
  function r.ImGui_Begin(_ctx, _title, _open, _flags) return true, r._imgui_open end
  function r.ImGui_End(_ctx) end
  function r.ImGui_TextColored(_ctx, _col, _txt) end
  function r.ImGui_Text(_ctx, _txt) end
  function r.ImGui_TextWrapped(_ctx, _txt) end
  function r.ImGui_Separator(_ctx) end
  function r.ImGui_Spacing(_ctx) end
  function r.ImGui_SameLine(_ctx) end
  function r.ImGui_GetContentRegionAvail(_ctx) return 500, 400 end
  function r.ImGui_SetNextItemWidth(_ctx, _w) end
  function r.ImGui_InputText(_ctx, _lbl, val, _flags) return false, val end
  function r.ImGui_BeginDisabled(_ctx, _d) end
  function r.ImGui_EndDisabled(_ctx) end
  function r.ImGui_Button(_ctx, lbl)
    if lbl:find("Browse") and r._imgui_trigger_browse then
      r._imgui_trigger_browse = false
      return true
    end
    if lbl:find("Import") and r._imgui_trigger_import then
      r._imgui_trigger_import = false
      return true
    end
    return false
  end
  function r.GetUserFileNameForRead(_fn, _title, _ext)
    if r._imgui_browse_path ~= "" then
      return true, r._imgui_browse_path
    end
    return false, ""
  end
  function r.ImGui_ProgressBar(_ctx, _frac, _w, _h, _overlay) end
  function r.ImGui_BeginChild(_ctx, _id, _w, _h) return true end
  function r.ImGui_EndChild(_ctx) end
  function r.ImGui_PushStyleColor(_ctx, _idx, _col) end
  function r.ImGui_PopStyleColor(_ctx) end
  function r.ImGui_GetScrollY(_ctx) return 0 end
  function r.ImGui_GetScrollMaxY(_ctx) return 0 end
  function r.ImGui_SetScrollHereY(_ctx, _y) end

  return r
end

-- Helpers
function mock.add_track(r, name)
  local t = r.InsertTrackAtIndex(#r._tracks)
  t.name = name or ""
  return t
end

function mock.add_item_to_track(_r, track, opts)
  opts = opts or {}
  opts.track = track
  local it = new_item(opts)
  track.items[#track.items + 1] = it
  return it
end

function mock.select_tracks(r, tracks)
  r._selected_tracks = tracks or {}
end

function mock.select_items(r, items)
  r._selected_items = items or {}
end

function mock.console(r)
  return table.concat(r._messages, "")
end

function mock.run_script(r, path)
  local had_reaper = rawget(_G, "reaper")
  local previous = _G.reaper
  _G.reaper = r
  local env = setmetatable({ reaper = r }, { __index = _G })

  local source = assert(io.open(path, "r")):read("*a")
  local chunk, err = load(source, "@" .. path, "t", env)
  if not chunk then
    _G.reaper = previous
    if not had_reaper then _G.reaper = nil end
    return "load: " .. tostring(err)
  end

  local ok, runtime_err = pcall(chunk)
  _G.reaper = previous
  if not had_reaper then _G.reaper = nil end

  if ok then return nil end
  return tostring(runtime_err)
end

return mock
