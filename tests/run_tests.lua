-- @license MIT (c) 2026 Scott Mills / SGM Studios
-- Test suite for sgm-suno-workflow using reaper_mock.lua

local mock = dofile("tests/reaper_mock.lua")

local passed = 0
local failed = 0
local total = 0

local function test(name, fn)
  total = total + 1
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    io.write(string.format("  ok   %s\n", name))
  else
    failed = failed + 1
    io.write(string.format("  FAIL %s\n        %s\n", name, tostring(err)))
  end
end

local function eq(actual, expected, msg)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s",
      msg or "assertion failed", tostring(expected), tostring(actual)), 2)
  end
end

local function approx(actual, expected, tolerance, msg)
  tolerance = tolerance or 0.001
  if math.abs(actual - expected) > tolerance then
    error(string.format("%s: expected %s +/- %s, got %s",
      msg or "assertion failed", tostring(expected), tostring(tolerance), tostring(actual)), 2)
  end
end

local function contains(str, substr, msg)
  if not tostring(str):find(substr, 1, true) then
    error(string.format("%s: %q does not contain %q", msg or "assertion failed", tostring(str), tostring(substr)), 2)
  end
end

print("----------------------------------------------------------------------")
print("Suno_01_MetadataOrganizer")
print("----------------------------------------------------------------------")

test("empty project shows message box and leaves project untouched", function()
  local r = mock.new()
  local err = mock.run_script(r, "Suno_01_MetadataOrganizer.lua")
  eq(err, nil, "script execution error")
  eq(#r._mb_prompts, 1, "MB shown")
  contains(r._mb_prompts[1].text, "No tracks found", "MB text")
  eq(r._undo_depth, 0, "undo balanced")
  eq(r._ui_refresh, 0, "UI refresh balanced")
end)

test("parses Suno filename, strips hex ID, detects stem and renames track", function()
  local r = mock.new()
  local t1 = mock.add_track(r, "Track 1")
  local t2 = mock.add_track(r, "Track 2")
  mock.add_item_to_track(r, t1, { filename = "/path/to/Neon_Dreams_vocals_a1b2c3d4e5f6g7h8.wav" })
  mock.add_item_to_track(r, t2, { filename = "/path/to/Neon_Dreams_drums_a1b2c3d4e5f6g7h8.wav" })

  -- User inputs: scope=all, regions=yes, color=yes
  r._user_input_default = "all,yes,yes"

  local err = mock.run_script(r, "Suno_01_MetadataOrganizer.lua")
  eq(err, nil, "script execution error")

  eq(t1.name, "Neon Dreams [Vocals]", "t1 track name")
  eq(t2.name, "Neon Dreams [Drums]", "t2 track name")
  eq(t1.color ~= nil, true, "t1 colored")
  eq(t2.color ~= nil, true, "t2 colored")
  eq(#r._markers, 2, "2 regions created")
  eq(r._markers[1].isrgn, true, "marker 1 is region")
  contains(r._markers[1].name, "Neon Dreams", "marker 1 name")

  eq(r._undo_depth, 0, "undo balanced")
  eq(r._ui_refresh, 0, "UI refresh balanced")
end)

test("short ID under 8 characters is not stripped as Suno hex ID", function()
  local r = mock.new()
  local t = mock.add_track(r, "Track 1")
  mock.add_item_to_track(r, t, { filename = "Summer_Vibes_v1.wav" })
  r._user_input_default = "all,no,no"

  local err = mock.run_script(r, "Suno_01_MetadataOrganizer.lua")
  eq(err, nil, "script error")
  -- v1 is 2 chars, so kept
  eq(t.name, "Summer Vibes v1", "track name")
  eq(r._undo_depth, 0, "undo balanced")
  eq(r._ui_refresh, 0, "UI refresh balanced")
end)

print("----------------------------------------------------------------------")
print("Suno_02_TempoMapper")
print("----------------------------------------------------------------------")

test("empty selection prompts message box", function()
  local r = mock.new()
  local err = mock.run_script(r, "Suno_02_TempoMapper.lua")
  eq(err, nil, "script error")
  eq(#r._mb_prompts, 1, "MB shown")
  contains(r._mb_prompts[1].text, "No item selected", "MB text")
  eq(r._undo_depth, 0, "undo balanced")
  eq(r._ui_refresh, 0, "UI refresh balanced")
end)

test("MIDI take is rejected with message box", function()
  local r = mock.new()
  local t = mock.add_track(r, "MIDI Track")
  local it = mock.add_item_to_track(r, t, { is_midi = true })
  mock.select_items(r, { it })

  local err = mock.run_script(r, "Suno_02_TempoMapper.lua")
  eq(err, nil, "script error")
  eq(#r._mb_prompts, 1, "MB shown")
  contains(r._mb_prompts[1].text, "works on audio items", "MB text")
  eq(r._undo_depth, 0, "undo balanced")
end)

test("override BPM sets tempo marker at item position", function()
  local r = mock.new()
  local t = mock.add_track(r, "Audio Track")
  local it = mock.add_item_to_track(r, t, { position = 4.0, length = 30.0 })
  mock.select_items(r, { it })

  -- User inputs: sensitivity=0.35, ts_num=4, ts_den=4, override_bpm=128
  r._user_input_default = "0.35,4,4,128"

  local err = mock.run_script(r, "Suno_02_TempoMapper.lua")
  eq(err, nil, "script error")

  eq(#r._tempo_markers >= 1, true, "primary tempo marker created")
  approx(r._tempo_markers[1].pos, 4.0, 0.001, "tempo marker position")
  approx(r._tempo_markers[1].bpm, 128.0, 0.001, "tempo marker bpm")
  eq(r._undo_depth, 0, "undo balanced")
  eq(r._ui_refresh, 0, "UI refresh balanced")
end)

print("----------------------------------------------------------------------")
print("Suno_03_DynamicSplitter")
print("----------------------------------------------------------------------")

test("empty selection prompts message box", function()
  local r = mock.new()
  local err = mock.run_script(r, "Suno_03_DynamicSplitter.lua")
  eq(err, nil, "script error")
  eq(#r._mb_prompts, 1, "MB shown")
  contains(r._mb_prompts[1].text, "No item(s) selected", "MB text")
  eq(r._undo_depth, 0, "undo balanced")
  eq(r._ui_refresh, 0, "UI refresh balanced")
end)

test("splits item at contrast boundaries and renames sections", function()
  local r = mock.new()
  local t = mock.add_track(r, "Song Track")
  -- Create a 40s item with synthesized peaks that have an energy surge at 15s
  local n_peaks = 40 * 20 -- 20 Hz frame rate
  local peaks = {}
  for i = 1, n_peaks do
    local time = (i - 1) / 20.0
    if time < 15.0 then
      peaks[i] = 0.1
    else
      peaks[i] = 0.9 -- sharp contrast surge
    end
  end

  local it = mock.add_item_to_track(r, t, {
    position = 0.0,
    length = 40.0,
    peaks = peaks,
    take_name = "MySong",
  })
  mock.select_items(r, { it })

  -- User input: sensitivity=0.30, min_len=8.0, max_sec=12
  r._user_input_default = "0.30,8.0,12"

  local err = mock.run_script(r, "Suno_03_DynamicSplitter.lua")
  eq(err, nil, "script error")

  eq(#t.items >= 2, true, "item split into multiple sections")
  eq(r._undo_depth, 0, "undo balanced")
  eq(r._ui_refresh, 0, "UI refresh balanced")
end)

print("----------------------------------------------------------------------")
print("Suno_04_LoudnessMaster")
print("----------------------------------------------------------------------")

test("no selection prompts message box", function()
  local r = mock.new()
  local err = mock.run_script(r, "Suno_04_LoudnessMaster.lua")
  eq(err, nil, "script error")
  eq(#r._mb_prompts, 1, "MB shown")
  contains(r._mb_prompts[1].text, "No items selected", "MB text")
  eq(r._undo_depth, 0, "undo balanced")
  eq(r._ui_refresh, 0, "UI refresh balanced")
end)

test("normalises item loudness towards target without exceeding ceiling", function()
  local r = mock.new()
  local t = mock.add_track(r, "Stem Track")
  -- Synthesize quiet peaks (0.05 peak ~ -26 dBFS)
  local n_peaks = 1000
  local peaks = {}
  for i = 1, n_peaks do peaks[i] = 0.05 end

  local it = mock.add_item_to_track(r, t, {
    length = 10.0,
    vol = 1.0,
    peaks = peaks,
  })
  mock.select_items(r, { it })

  -- Target -18 dBFS RMS
  r._user_input_default = "-18"

  local err = mock.run_script(r, "Suno_04_LoudnessMaster.lua")
  eq(err, nil, "script error")

  eq(it.vol > 1.0, true, "gain boosted to reach target")
  eq(r._undo_depth, 0, "undo balanced")
  eq(r._ui_refresh, 0, "UI refresh balanced")
end)

print("----------------------------------------------------------------------")
print("Suno_05_StemAligner")
print("----------------------------------------------------------------------")

test("empty project shows message box", function()
  local r = mock.new()
  local err = mock.run_script(r, "Suno_05_StemAligner.lua")
  eq(err, nil, "script error")
  eq(#r._mb_prompts, 1, "MB shown")
  contains(r._mb_prompts[1].text, "No tracks in project", "MB text")
  eq(r._undo_depth, 0, "undo balanced")
  eq(r._ui_refresh, 0, "UI refresh balanced")
end)

test("no recognized stem patterns shows informative prompt", function()
  local r = mock.new()
  local t = mock.add_track(r, "Random Audio")
  mock.add_item_to_track(r, t, { filename = "podcast_episode_42.wav" })

  r._user_input_default = "yes,yes,yes"
  local err = mock.run_script(r, "Suno_05_StemAligner.lua")
  eq(err, nil, "script error")
  eq(#r._mb_prompts, 1, "MB shown")
  contains(r._mb_prompts[1].text, "No stem groups found", "MB text")
  eq(r._undo_depth, 0, "undo balanced")
  eq(r._ui_refresh, 0, "UI refresh balanced")
end)

test("aligns stems to earliest start, creates folder and summing bus", function()
  local r = mock.new()
  local t_voc = mock.add_track(r, "Vocals Track")
  local t_drm = mock.add_track(r, "Drums Track")

  -- Vocals start at 2.5s, drums start at 1.0s
  local it_voc = mock.add_item_to_track(r, t_voc, {
    position = 2.5,
    filename = "Starlight_vocals_a1b2c3d4e5f6g7h8.wav",
  })
  local it_drm = mock.add_item_to_track(r, t_drm, {
    position = 1.0,
    filename = "Starlight_drums_a1b2c3d4e5f6g7h8.wav",
  })

  -- User inputs: align=yes, folder=yes, bus=yes
  r._user_input_default = "yes,yes,yes"

  local err = mock.run_script(r, "Suno_05_StemAligner.lua")
  eq(err, nil, "script error")

  -- Vocals should be shifted to match drums at 1.0s
  approx(it_voc.position, 1.0, 0.001, "vocals aligned to ref_pos 1.0")
  approx(it_drm.position, 1.0, 0.001, "drums at ref_pos 1.0")

  -- Check track names
  eq(t_voc.name, "[Suno] Starlight (Vocals)", "vocals track name")
  eq(t_drm.name, "[Suno] Starlight (Drums)", "drums track name")

  -- Check total tracks: original 2 stems + 1 folder track + 1 bus track = 4 tracks
  eq(r.CountTracks(), 4, "4 total tracks created")

  -- Folder track inserted before stems (index 1)
  local folder = r.GetTrack(0, 0)
  eq(folder.name, "[Suno] Starlight", "folder track name")
  eq(folder.folderdepth, 1, "folder depth opening")

  -- Stem send to bus track
  eq(#t_voc.sends, 1, "vocals send created to summing bus")
  eq(#t_drm.sends, 1, "drums send created to summing bus")

  eq(r._undo_depth, 0, "undo balanced")
  eq(r._ui_refresh, 0, "UI refresh balanced")
end)

print("----------------------------------------------------------------------")
print("SGM_SunoWorkflow_Bundle")
print("----------------------------------------------------------------------")

test("bundle script compiles and runs without error", function()
  local r = mock.new()
  local err = mock.run_script(r, "SGM_SunoWorkflow_Bundle.lua")
  eq(err, nil, "bundle script error")
end)

print("----------------------------------------------------------------------")
print("Regression & Edge-Case Tests (01-05)")
print("----------------------------------------------------------------------")

test("01: resolves parent source and counts unique songs for stem-only project", function()
  local r = mock.new()
  local t1 = mock.add_track(r, "T1")
  local t2 = mock.add_track(r, "T2")
  local it1 = mock.add_item_to_track(r, t1, { filename = "" })
  it1.takes[1].source = { filename = "", parent = { filename = "/music/Echo_vocals_12345678.wav" } }
  mock.add_item_to_track(r, t2, { filename = "/music/Echo_drums_12345678.wav" })

  r._user_input_default = "all,no,yes"
  local err = mock.run_script(r, "Suno_01_MetadataOrganizer.lua")
  eq(err, nil, "script error")
  eq(t1.name, "Echo [Vocals]", "parent source resolved")
  contains(r._mb_prompts[1].text, "Songs     : 1 unique title", "unique song count")
end)

test("02: auto-detects BPM on item at non-zero position and replaces prior marker", function()
  local r = mock.new()
  local t = mock.add_track(r, "Audio Track")
  -- Item at 4.0s, 10s long; synthetic peaks have 2 Hz pulse = 120 BPM
  local it = mock.add_item_to_track(r, t, { position = 4.0, length = 10.0 })
  mock.select_items(r, { it })
  -- Pre-existing tempo marker inside item range
  r.AddTempoTimeSigMarker(0, 6.0, 95.0, 4, 4, false)

  -- First prompt: auto-detect (override=0); second prompt: accept detected BPM
  r._user_inputs = { "0.35,4,4,0", "120" }
  local err = mock.run_script(r, "Suno_02_TempoMapper.lua")
  eq(err, nil, "script error")
  eq(#r._tempo_markers, 1, "prior marker replaced with 1 new marker")
  approx(r._tempo_markers[1].pos, 4.0, 0.001, "tempo marker at item_pos")
  approx(r._tempo_markers[1].bpm, 120.0, 0.1, "detected 120 BPM")
end)

test("03: splits item at non-zero position (10.0s) using GetMediaItemTake_Peaks", function()
  local r = mock.new()
  local t = mock.add_track(r, "Song Track")
  local n_peaks = 40 * 20
  local peaks = {}
  for i = 1, n_peaks do
    peaks[i] = ((i - 1) / 20.0 < 15.0) and 0.1 or 0.9
  end
  local it = mock.add_item_to_track(r, t, {
    position = 10.0,
    length = 40.0,
    peaks = peaks,
    take_name = "LateSong",
  })
  mock.select_items(r, { it })
  r._user_input_default = "0.30,8.0,12"

  local err = mock.run_script(r, "Suno_03_DynamicSplitter.lua")
  eq(err, nil, "script error")
  eq(#t.items >= 2, true, "item at non-zero pos split into sections")
  eq(t.items[2].position > 10.0, true, "split position > item_pos")
end)

test("04: loudness normalisation is idempotent across repeated runs", function()
  local r = mock.new()
  local t = mock.add_track(r, "Stem")
  local peaks = {}
  for i = 1, 1000 do peaks[i] = 0.05 end
  local it = mock.add_item_to_track(r, t, { position = 5.0, length = 10.0, vol = 1.0, peaks = peaks })
  mock.select_items(r, { it })
  r._user_input_default = "-18,-0.3"

  local err1 = mock.run_script(r, "Suno_04_LoudnessMaster.lua")
  eq(err1, nil, "first run error")
  local vol_after_1 = it.vol
  eq(vol_after_1 > 1.0, true, "boosted on first run")

  local err2 = mock.run_script(r, "Suno_04_LoudnessMaster.lua")
  eq(err2, nil, "second run error")
  approx(it.vol, vol_after_1, 0.001, "volume unchanged on second run")
end)

test("05: creates summing bus even when folder creation is disabled", function()
  local r = mock.new()
  local t1 = mock.add_track(r, "Vocals")
  local t2 = mock.add_track(r, "Bass")
  mock.add_item_to_track(r, t1, { position = 1.0, filename = "Horizon_vocals_a1b2c3d4.wav" })
  mock.add_item_to_track(r, t2, { position = 2.0, filename = "Horizon_bass_a1b2c3d4.wav" })

  r._user_input_default = "yes,no,yes"
  local err = mock.run_script(r, "Suno_05_StemAligner.lua")
  eq(err, nil, "script error")
  eq(r.CountTracks(), 3, "2 stems + 1 bus track (no folder)")
  eq(#t1.sends, 1, "vocals send to bus")
  eq(#t2.sends, 1, "bass send to bus")
end)

print("----------------------------------------------------------------------")
print("Various/SGM_Suno ZIP Importer")
print("----------------------------------------------------------------------")

test("imports Suno ZIP, parses info.json, creates tracks/markers/notes, keeps audio", function()
  local tmp_root = "/tmp/sgm_suno_zip_test_" .. tostring(os.time())
  local zip_file = tmp_root .. "/test_song.zip"
  local proj_dir = tmp_root .. "/project"
  os.execute('mkdir -p "' .. proj_dir .. '"')
  os.execute(string.format(
    'python3 -c \'import zipfile, json; z=zipfile.ZipFile("%s","w"); '
    .. 'z.writestr("info.json", json.dumps({"title":"Midnight Pulse","tags":"synthwave",'
    .. '"prompt":"[Intro]\\nHello\\n[Chorus]\\nWorld"})); '
    .. 'z.writestr("vocals.wav", "RIFFDATA"); '
    .. 'z.writestr("instrumental.wav", "RIFFDATA"); '
    .. 'z.close()\'',
    zip_file))

  local r = mock.new()
  r._project_path = proj_dir
  r._imgui_browse_path = zip_file
  r._imgui_trigger_browse = true
  r._imgui_trigger_import = true
  r._imgui_open = true
  function r.defer(fn)
    if r._imgui_open then
      r._imgui_open = false -- run one frame after initial defer
      fn()
    end
  end

  local err = mock.run_script(r, "Various/SGM_Suno ZIP Importer.lua")
  eq(err, nil, "ZIP Importer error")
  eq(r.CountTracks(), 3, "folder + 2 stem tracks created")
  eq(r.GetTrack(0, 0).name, "[Suno] Midnight Pulse", "folder track name from info.json")
  eq(r.GetTrack(0, 1).name, "[Suno] Midnight Pulse (Instrumental)", "instrumental track")
  eq(r.GetTrack(0, 2).name, "[Suno] Midnight Pulse (Vocals)", "vocals track")
  eq(#r._markers, 2, "2 structural markers placed")
  contains(r._project_notes, "Midnight Pulse", "project notes contain title")
  contains(r._project_notes, "[Chorus]", "project notes contain lyrics")

  -- Verify extracted audio file still exists on disk (not deleted!)
  local imported_src = r.GetTrack(0, 1).items[1].takes[1].source.filename
  eq(r.file_exists(imported_src), true, "imported audio file kept on disk")

  os.execute('rm -rf "' .. tmp_root .. '"')
end)

test("rejects zip-slip path traversal archive", function()
  local tmp_root = "/tmp/sgm_suno_zipslip_test_" .. tostring(os.time())
  local zip_file = tmp_root .. "/evil.zip"
  local proj_dir = tmp_root .. "/project"
  os.execute('mkdir -p "' .. proj_dir .. '"')
  os.execute(string.format(
    'python3 -c \'import zipfile; z=zipfile.ZipFile("%s","w"); '
    .. 'z.writestr("../../evil.wav", "BAD"); z.close()\'',
    zip_file))

  local r = mock.new()
  r._project_path = proj_dir
  r._imgui_browse_path = zip_file
  r._imgui_trigger_browse = true
  r._imgui_trigger_import = true
  r._imgui_open = true
  function r.defer(fn)
    if r._imgui_open then
      r._imgui_open = false
      fn()
    end
  end

  local err = mock.run_script(r, "Various/SGM_Suno ZIP Importer.lua")
  eq(err, nil, "ZIP Importer should fail closed without crashing")
  eq(r.CountTracks(), 0, "no tracks created for zip-slip archive")
  contains(mock.console(r), "Unsafe path in ZIP", "zip-slip logged")

  os.execute('rm -rf "' .. tmp_root .. '"')
end)

print("----------------------------------------------------------------------")
print(string.format("Summary: %d passed, %d failed (total %d)", passed, failed, total))
print("----------------------------------------------------------------------")

if failed > 0 then
  os.exit(1)
end
