--[[============================================================================
  test_05_stems.lua — Suno_05_StemAligner
============================================================================]]--

local harness = require("harness")

local function add_stem(P, filename, pos, opts)
  opts = opts or {}
  local src = P:add_source(filename, 2, 44100, 10.0, harness.sine_signal(0.3))
  local tr = P:add_track("tmp", opts)
  local item = P:add_item(tr, src, pos or 0, 10.0)
  return tr, item
end

local function run(P, answer)
  harness.answer(P, answer or "yes,yes,yes")
  local _, ok, err = harness.run("Suno_05_StemAligner.lua", P)
  return ok, err
end

-- Index of the track that closes the folder opened at `folder_idx`.
local function folder_span(P, folder_idx)
  local depth = P.tracks[folder_idx].folderdepth
  if depth ~= 1 then return nil end
  local level, last = 1, nil
  for i = folder_idx + 1, #P.tracks do
    last = i
    level = level + (P.tracks[i].folderdepth or 0)
    if level <= 0 then return i end
  end
  return last
end

return function(t)

  t.group("Suno_05 StemAligner")

  t.test("groups stems, aligns starts, builds folders and buses", function()
    local P = harness.project()
    local av, avi = add_stem(P, "/m/SongA_vocals_aa11bb22cc33.wav", 1.0)
    local ad, adi = add_stem(P, "/m/SongA_drums_aa11bb22cc33.wav", 2.5)
    local _, bvi = add_stem(P, "/m/SongB_vocals_dd44ee55ff66.wav", 0.0)
    local _, bbi = add_stem(P, "/m/SongB_bass_dd44ee55ff66.wav", 0.75)

    local ok, err = run(P)
    t.ok(ok, "script runs (got: " .. tostring(err) .. ")")

    -- Alignment
    t.approx(avi.pos, 1.0, 0.0001, "group A vocals stay put (earliest)")
    t.approx(adi.pos, 1.0, 0.0001, "group A drums aligned to the earliest start")
    t.approx(bvi.pos, 0.0, 0.0001, "group B vocals stay put")
    t.approx(bbi.pos, 0.0, 0.0001, "group B bass aligned to the earliest start")

    -- Structure: 4 stems + 2 folders + 2 buses
    t.eq(#P.tracks, 8, "four stems plus a folder and a bus per song")
    t.eq(P:folder_balance(), 0, "folder depths balance to zero")

    -- Naming + colours
    t.ok(av.name:find("[Suno] SongA (Vocals)", 1, true) ~= nil,
         "stem renamed (got " .. tostring(av.name) .. ")")
    t.ok(ad.name:find("SongA (Drums)", 1, true) ~= nil, "drums renamed")

    -- Folder placement
    t.eq(P.tracks[1].name, "[Suno] SongA", "folder opens above the group")
    t.eq(P.tracks[1].folderdepth, 1, "folder depth = 1")
    local closeA = folder_span(P, 1)
    t.ok(closeA ~= nil, "folder A is closed")
    if closeA then
      t.eq(P.tracks[closeA].folderdepth, -1, "the last child closes the folder")
      t.ok(P.tracks[closeA] == ad, "the last SongA stem closes the folder")
    end

    -- Buses
    local function find_track(needle)
      for _, tr in ipairs(P.tracks) do
        if tr.name:find(needle, 1, true) then return tr end
      end
    end
    local busA = find_track("[Suno] SongA  [BUS]")
    local busB = find_track("[Suno] SongB  [BUS]")
    t.ok(busA ~= nil, "bus for SongA exists")
    t.ok(busB ~= nil, "bus for SongB exists")

    if busA then
      t.eq(#av.sends, 1, "SongA vocals routed to the bus")
      t.eq(av.sends[1].dest, busA, "send targets the SongA bus")
      t.eq(av.sends[1].mode, 0, "send is post-fader")
      t.eq(#ad.sends, 1, "SongA drums routed to the bus")
      t.eq(#av.sends + #ad.sends, 2, "exactly one send per stem")
    end
  end)

  t.test("a bus is still created when folders are disabled", function()
    local P = harness.project()
    add_stem(P, "/m/SongA_vocals_aa11bb22cc33.wav", 0)
    add_stem(P, "/m/SongA_drums_aa11bb22cc33.wav", 0)

    local ok = run(P, "yes,no,yes")
    t.ok(ok, "script runs")
    t.eq(#P.tracks, 3, "two stems plus one bus, no folder")
    local bus
    for _, tr in ipairs(P.tracks) do
      if tr.name:find("[BUS]", 1, true) then bus = tr end
    end
    t.ok(bus ~= nil, "bus created without a folder")
    t.eq(P:folder_balance(), 0, "no folder depth introduced")
  end)

  t.test("folder and bus can both be disabled", function()
    local P = harness.project()
    add_stem(P, "/m/SongA_vocals_aa11bb22cc33.wav", 0)
    add_stem(P, "/m/SongA_drums_aa11bb22cc33.wav", 2.0)
    local ok = run(P, "yes,no,no")
    t.ok(ok, "script runs")
    t.eq(#P.tracks, 2, "no tracks added")
    t.approx(P.tracks[2].items[1].pos, 0, 0.0001, "alignment still applied")
  end)

  t.test("does not wrap another song's track in a folder", function()
    local P = harness.project()
    add_stem(P, "/m/SongA_vocals_aa11bb22cc33.wav", 0)   -- track 1
    add_stem(P, "/m/SongB_vocals_dd44ee55ff66.wav", 0)   -- track 2 (interleaved!)
    add_stem(P, "/m/SongA_drums_aa11bb22cc33.wav", 0)    -- track 3

    local ok = run(P)
    t.ok(ok, "script runs")
    t.eq(P:folder_balance(), 0, "no unbalanced folder")
    for _, tr in ipairs(P.tracks) do
      t.ok(tr.name ~= "[Suno] SongA", "no folder spans the interleaved SongB track")
    end
    t.ok(harness.console_contains(P, "not on adjacent tracks"),
         "console explains why the folder was skipped")
  end)

  t.test("leaves an existing folder hierarchy untouched", function()
    local P = harness.project()
    local existing = P:add_track("Existing folder", { folderdepth = 1 })
    local a = add_stem(P, "/m/SongA_vocals_aa11bb22cc33.wav", 0)
    add_stem(P, "/m/SongA_drums_aa11bb22cc33.wav", 0)
    existing.items = existing.items or {}

    local ok = run(P, "yes,yes,no")
    t.ok(ok, "script runs")
    t.eq(existing.folderdepth, 1, "pre-existing folder still open")
    t.eq(a.folderdepth, 0, "stem depth untouched")
  end)

  t.test("single-stem groups are skipped", function()
    local P = harness.project()
    add_stem(P, "/m/Solo_vocals_aa11bb22cc33.wav", 0)
    local ok = run(P)
    t.ok(ok, "script exits cleanly")
    t.ok(harness.dialogs_contain(P, "No stem groups"), "explains that nothing matched")
  end)

  t.test("non-stem tracks are ignored", function()
    local P = harness.project()
    local src = P:add_source("/m/mystery.wav", 2, 44100, 5.0, harness.sine_signal(0.2))
    local tr = P:add_track("mystery")
    P:add_item(tr, src, 0, 5.0)
    local ok = run(P)
    t.ok(ok, "script exits cleanly")
    t.eq(tr.name, "mystery", "unrecognised track untouched")
    t.eq(#P.tracks, 1, "no tracks added")
  end)

  t.test("undo block is balanced", function()
    local P = harness.project()
    add_stem(P, "/m/SongA_vocals_aa11bb22cc33.wav", 1)
    add_stem(P, "/m/SongA_drums_aa11bb22cc33.wav", 2)
    local ok = run(P)
    t.ok(ok, "script runs")
    t.eq(P.undo_depth, 0, "undo balanced")
  end)
end
