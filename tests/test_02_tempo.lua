--[[============================================================================
  test_02_tempo.lua — Suno_02_TempoMapper
============================================================================]]--

local harness = require("harness")

return function(t)

  t.group("Suno_02 TempoMapper")

  t.test("detects 128 BPM from the peak cache", function()
    local P = harness.project()
    local src = P:add_source("/audio/click128.wav", 2, 44100, 8.0,
                             harness.click_signal(128, 0.8))
    local tr = P:add_track("Click")
    P:add_item(tr, src, 10.0, 8.0, { selected = true })

    harness.answer(P, "0.35,4,4,0")   -- sensitivity / timesig / override
    harness.answer(P, "@default")     -- accept the detected BPM

    local _, ok, err = harness.run("Suno_02_TempoMapper.lua", P)

    t.ok(ok, "script runs without error (got: " .. tostring(err) .. ")")
    t.ok(not P.oob, "peak buffer is not over-read")
    t.eq(#P.tempo, 1, "exactly one tempo marker inserted")
    if P.tempo[1] then
      t.approx(P.tempo[1].bpm, 128, 2.5, "detected BPM")
      t.approx(P.tempo[1].pos, 10.0, 0.01, "tempo marker sits at the item start")
      t.eq(P.tempo[1].num, 4, "time signature numerator")
      t.eq(P.tempo[1].den, 4, "time signature denominator")
    end
    t.approx(P.cursor, 0, 0.001, "edit cursor restored")
    t.eq(P.undo_depth, 0, "undo block balanced")
  end)

  t.test("manual BPM override wins", function()
    local P = harness.project()
    local src = P:add_source("/audio/x.wav", 2, 44100, 4.0, harness.click_signal(128, 0.8))
    local tr = P:add_track("X")
    P:add_item(tr, src, 0, 4.0, { selected = true })

    harness.answer(P, "0.35,4,4,120")
    local _, ok, err = harness.run("Suno_02_TempoMapper.lua", P)

    t.ok(ok, "script runs (got: " .. tostring(err) .. ")")
    t.ok(#P.tempo >= 1, "tempo marker inserted")
    if P.tempo[1] then t.approx(P.tempo[1].bpm, 120, 0.001, "override BPM") end
  end)

  t.test("guard marker restores the previous project tempo after the item", function()
    -- Existing content after the analysed item must keep the project tempo.
    local P = harness.project()
    local src = P:add_source("/audio/a.wav", 2, 44100, 4.0, harness.click_signal(100, 0.8))
    local tr = P:add_track("A")
    P:add_item(tr, src, 0, 4.0, { selected = true })
    local other = P:add_track("B")
    local src2 = P:add_source("/audio/b.wav", 2, 44100, 4.0, harness.sine_signal(0.3))
    P:add_item(other, src2, 20.0, 4.0)

    harness.answer(P, "0.35,4,4,96")
    local _, ok, err = harness.run("Suno_02_TempoMapper.lua", P)

    t.ok(ok, "script runs (got: " .. tostring(err) .. ")")
    t.eq(#P.tempo, 2, "tempo marker + guard marker")
    if P.tempo[2] then
      t.approx(P.tempo[2].pos, 4.0, 0.01, "guard marker at item end")
      t.ne(P.tempo[2].bpm, 96, "guard marker does not simply repeat the new tempo")
    end
  end)

  t.test("refuses to run with no selection", function()
    local P = harness.project()
    local _, ok = harness.run("Suno_02_TempoMapper.lua", P)
    t.ok(ok, "script exits cleanly")
    t.eq(#P.tempo, 0, "no tempo markers added")
    t.ok(harness.dialogs_contain(P, "No item selected"), "explains the problem")
  end)

  t.test("silent audio produces a clear error, not a bogus tempo", function()
    local P = harness.project()
    local src = P:add_source("/audio/silent.wav", 2, 44100, 4.0, harness.silence())
    local tr = P:add_track("Silent")
    P:add_item(tr, src, 0, 4.0, { selected = true })

    harness.answer(P, "0.35,4,4,0")
    harness.answer(P, false)          -- user cancels the manual-BPM prompt
    local _, ok, err = harness.run("Suno_02_TempoMapper.lua", P)

    t.ok(ok, "script runs (got: " .. tostring(err) .. ")")
    t.eq(#P.tempo, 0, "no tempo marker for silent audio")
    t.ok(harness.console_contains(P, "silent") or harness.console_contains(P, "quiet"),
         "console explains that the audio is silent")
  end)

  t.test("deep-integer peak counts are masked (no giant loop)", function()
    local P = harness.project()
    local src = P:add_source("/audio/c.wav", 2, 44100, 6.0, harness.click_signal(90, 0.7))
    local tr = P:add_track("C")
    P:add_item(tr, src, 0, 6.0, { selected = true })
    harness.answer(P, "0.35,4,4,0")
    harness.answer(P, "@default")
    local _, ok, err = harness.run("Suno_02_TempoMapper.lua", P)
    t.ok(ok, "script runs (got: " .. tostring(err) .. ")")
    t.ok(not P.oob, "no out-of-bounds buffer access")
  end)
end
