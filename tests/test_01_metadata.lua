--[[============================================================================
  test_01_metadata.lua — Suno_01_MetadataOrganizer
============================================================================]]--

local harness = require("harness")

local function project_with(files, opts)
  local P = harness.project()
  opts = opts or {}
  for i, filename in ipairs(files) do
    local src = P:add_source(filename, 2, 44100, 10.0, harness.sine_signal(0.3))
    local tr = P:add_track("Track " .. i)
    P:add_item(tr, src, opts.pos or 0, 10.0, { selected = opts.selected or false })
  end
  return P
end

local function run(P, answer)
  harness.answer(P, answer or "all,yes,yes")
  local _, ok, err = harness.run("Suno_01_MetadataOrganizer.lua", P)
  return ok, err
end

return function(t)

  t.group("Suno_01 MetadataOrganizer")

  t.test("renames tracks from Suno filenames and strips the ID", function()
    local P = project_with({
      "/m/MySong_vocals_a1b2c3d4e5f6g7h8.wav",
      "/m/MySong_drums_a1b2c3d4e5f6g7h8.wav",
      "/m/other-song_0123456789abcdef.mp3",
    })
    local ok, err = run(P)
    t.ok(ok, "script runs (got: " .. tostring(err) .. ")")
    t.eq(P.tracks[1].name, "MySong [Vocals]", "vocals stem renamed")
    t.eq(P.tracks[2].name, "MySong [Drums]", "drums stem renamed")
    t.eq(P.tracks[3].name, "other song", "plain track renamed, ID stripped")
  end)

  t.test("handles the Suno ID before the stem suffix", function()
    local P = project_with({ "/m/CoolSong_abc123def456_vocals.wav" })
    local ok = run(P)
    t.ok(ok, "script runs")
    t.eq(P.tracks[1].name, "CoolSong [Vocals]",
         "ID removed even when it precedes the stem")
  end)

  t.test("keeps short tokens as part of the title", function()
    local P = project_with({ "/m/my-song (v2)_abcdef12.mp3" })
    local ok = run(P)
    t.ok(ok, "script runs")
    t.eq(P.tracks[1].name, "my song (v2)", "8-char ID stripped, dashes → spaces")
  end)

  t.test("instrumental-only file still gets a usable label", function()
    local P = project_with({ "/m/instrumental_abc123def456.wav" })
    local ok = run(P)
    t.ok(ok, "script runs")
    t.ok(P.tracks[1].name:find("[Instrumental]", 1, true) ~= nil,
         "label mentions the stem (got " .. tostring(P.tracks[1].name) .. ")")
  end)

  t.test("colours are assigned, and shared per song", function()
    local P = project_with({
      "/m/SongA_abc123def456_drums.wav",
      "/m/SongA_abc123def456_bass.wav",
      "/m/SongB_0123456789ab_full.wav",
    })
    local ok = run(P)
    t.ok(ok, "script runs")
    local c1, c2, c3 = P.tracks[1].color, P.tracks[2].color, P.tracks[3].color
    t.ok(c1 ~= 0 and c2 ~= 0 and c3 ~= 0, "every processed track is coloured")
    t.ok(c1 ~= c3 or c2 ~= c3, "different songs do not collide unnecessarily")
  end)

  t.test("creates one region per song span, not one per stem track", function()
    local P = project_with({
      "/m/SongA_abc123def456_vocals.wav",
      "/m/SongA_abc123def456_drums.wav",
      "/m/SongA_abc123def456_bass.wav",
    })
    local ok = run(P)
    t.ok(ok, "script runs")
    t.eq(#P.markers, 1, "three stems of one song → a single region")
    if P.markers[1] then
      t.eq(P.markers[1].isrgn, true, "a region, not a marker")
      t.approx(P.markers[1].pos, 0, 0.001, "region start")
      t.approx(P.markers[1].endpos, 10.0, 0.001, "region end")
      t.eq(P.markers[1].name, "SongA", "region named after the song")
    end
  end)

  t.test("distinct songs each get a region", function()
    local P = project_with({
      "/m/SongA_abc123def456_vocals.wav",
      "/m/SongB_abc123def457_vocals.wav",
    })
    local ok = run(P)
    t.ok(ok, "script runs")
    t.eq(#P.markers, 2, "two songs → two regions")
  end)

  t.test("regions can be disabled", function()
    local P = project_with({ "/m/SongA_abc123def456_vocals.wav" })
    local ok = run(P, "all,no,yes")
    t.ok(ok, "script runs")
    t.eq(#P.markers, 0, "no regions created")
    t.eq(P.tracks[1].name, "SongA [Vocals]", "rename still happens")
  end)

  t.test("colours can be disabled", function()
    local P = project_with({ "/m/SongA_abc123def456_vocals.wav" })
    local ok = run(P, "all,yes,no")
    t.ok(ok, "script runs")
    t.eq(P.tracks[1].color, 0, "colour untouched")
  end)

  t.test("scope=selected only touches selected tracks", function()
    local P = harness.project()
    local files = { "/m/SongA_abc123def456_vocals.wav", "/m/SongB_abc123def457_vocals.wav" }
    for i, f in ipairs(files) do
      local src = P:add_source(f, 2, 44100, 10.0, harness.sine_signal(0.3))
      local tr = P:add_track("Track " .. i, { selected = (i == 2) })
      P:add_item(tr, src, 0, 10.0, { selected = (i == 2) })
    end
    local ok = run(P, "selected,yes,yes")
    t.ok(ok, "script runs")
    t.eq(P.tracks[1].name, "Track 1", "unselected track untouched")
    t.eq(P.tracks[2].name, "SongB [Vocals]", "selected track renamed")
  end)

  t.test("undo block stays balanced and the cursor is restored", function()
    local P = project_with({ "/m/SongA_abc123def456_vocals.wav" })
    P.cursor = 3.25
    local ok = run(P)
    t.ok(ok, "script runs")
    t.eq(P.undo_depth, 0, "undo balanced")
    t.approx(P.cursor, 3.25, 0.0001, "edit cursor restored")
  end)

  t.test("no tracks → friendly message, no crash", function()
    local P = harness.project()
    local ok = run(P)
    t.ok(ok, "script exits cleanly")
    t.ok(harness.dialogs_contain(P, "No tracks"), "explains the problem")
  end)
end
